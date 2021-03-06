# MUST override input

package NGCP::Client::RTCP;

use strict;
use warnings;

use parent 'NGCP::Rtpclient::RTCP';

sub input {
    my ($self, $packet) = @_;

    print "This is NGCP::Client::RTCP\n";

    my ($vprc, $pt, $len, $rest) = unpack('CCn a*', $packet);
    ($vprc & 0xe0) == 0x80 or die "RTCP: Version mismatch";
    my $rc = ($vprc & 0x1f);
    $rc > 1 and die "RTCP: Reception report count > 1: <" . unpack('H*', $packet) . ">";
    print "RTCP: Original packet length: $len, PT=$pt\n";
    $len++;
    $len <<= 2;
    $len == length($packet) or
        warn "RTCP: length mismatch: $len != " . length($packet) . " <" . unpack('H*', $packet) . ">";

    if ($pt == 200) {
        my ($ssrc, @sr) = unpack('NNNNNN', $rest);
        $self->{last_sr}->{$ssrc} = { received_time => time(), packet => \@sr };
    }
}

1;

# Call with caller and callee

package NGCP::Rtpengine::Call;

use strict;
use warnings;
use Socket;
use Socket6;
use IO::Socket;
use IO::Socket::IP;
use Bencode;
use Data::Dumper;
use Net::Interface;
use List::Util;
use IO::Multiplex;
use Time::HiRes qw(time);
use NGCP::Rtpclient::SDP;
use NGCP::Rtpclient::ICE;
use NGCP::Rtpclient::SDES;
use NGCP::Rtpclient::DTLS;
use NGCP::Rtpclient::RTP;
# use NGCP::Rtpclient::RTCP;
use NGCP::Rtpengine;

# use NGCP::Client::RTCP;

sub new {
	my ($class, %args) = @_;

	my $self = {};
	bless $self, $class;

	srand(1234) if $ENV{RTPE_TEST_PSEUDO_RAND};

	# detect local interfaces

	my (@v4, @v6);
	my @intfs = Net::Interface->interfaces();

	if ($ENV{RTPE_TEST_V4_ADDRS}) {
		@v4 = split(/ /, $ENV{RTPE_TEST_V4_ADDRS});
	}
	else {
		@v4 = map {$_->address(&AF_INET)} @intfs;
		@v4 = map {Socket6::inet_ntop(&AF_INET, $_)} @v4;
		@v4 = grep {$_ !~ /^127\./} @v4;
	}
	@v4 = map { { address => $_, sockdomain => &AF_INET } } @v4;
	# @v4 or die("no IPv4 addresses found");

	if ($ENV{RTPE_TEST_V6_ADDRS}) {
		@v6 = split(/ /, $ENV{RTPE_TEST_V6_ADDRS});
	}
	else {
		@v6 = map {$_->address(&AF_INET6)} @intfs;
		@v6 = map {Socket6::inet_ntop(&AF_INET6, $_)} @v6;
		@v6 = grep {$_ !~ /^::|^fe80:/} @v6;
	}
	@v6 = map { { address => $_, sockdomain => &AF_INET6 } } @v6;
	# @v6 or die("no IPv6 addresses found");

	$self->{v4_addresses} = \@v4;
	$self->{v6_addresses} = \@v6;
	$self->{all_addresses} = [ @v4, @v6 ];

	# supporting objects

	$self->{mux} = IO::Multiplex->new();
	$self->{mux}->set_callback_object($self);

	$self->{media_port} = $args{media_port} // $ENV{RTPE_TEST_MEDIA_PORT} // 2000;
	$self->{timers} = [];
	$self->{clients} = [];

	$self->{control} = NGCP::Rtpengine->new($args{host} // $ENV{RTPENGINE_HOST} // 'localhost',
		$args{port} // $ENV{RTPENGINE_PORT} // 2223);
	$self->{callid} = "id-" . int(rand(2**32));

	return $self;
};

sub client {
	my ($self, %args) = @_;
	my $cl = NGCP::Rtpengine::Client->new($self, %args);
	push(@{$self->{clients}}, $cl);
	return $cl;
}

sub client_pair {
	my ($self, $args_A, $args_B) = @_;
	my $a = $self->client(%$args_A);
	my $b = $self->client(%$args_B);
	$a->media_receiver($b);
	$b->media_receiver($a);
	return ($a, $b);
}

sub run {
	my ($self) = @_;
	$self->{mux}->loop();
}

sub stop {
	my ($self) = @_;
	$self->{mux}->endloop();
	for my $cl (@{$self->{clients}}) {
		$cl->stop();
	}
}

sub timer_once {
	my ($self, $delay, $sub) = @_;
	push(@{$self->{timers}}, { sub => $sub, when => time() + $delay });
	@{$self->{timers}} = sort {$a->{when} <=> $b->{when}} @{$self->{timers}};
}

sub mux_input {
	my ($self, $mux, $fh, $input) = @_;

	my $peer = $mux->udp_peer($fh);

	for my $cl (@{$self->{clients}}) {
		$$input eq '' and last;
		$cl->_input($fh, $input, $peer);
	}

	unless($$input eq ''){
            warn __PACKAGE__ . "::mux_input: non-empty input: <" .
                unpack('H*', $$input) . ">";
            $$input = '';
        }
}

sub mux_timeout {
	my ($self, $mux, $fh) = @_;

	$mux->set_timeout($fh, 0.01);

	my $now = time();
	while (@{$self->{timers}} && $self->{timers}->[0]->{when} <= $now) {
		my $t = shift(@{$self->{timers}});
		$t->{sub}->();
	}

	for my $cl (@{$self->{clients}}) {
		$cl->_timer();
	}
}


package NGCP::Rtpengine::Client;

use Socket;
use Data::Dumper;

sub new {
	my ($class, $parent, %args) = @_;

	my $self = {};
	bless $self, $class;

	$self->{parent} = $parent;
	$self->{tag} = "tag-" . int(rand(2**32));
	$self->{codecs} = $args{codecs} // [qw(PCMU)];

	# create media sockets
        my $address = $args{address} // $parent->{all_addresses}->[0];
        my $port    = $args{port} // $parent->{media_port};
	my (@sockets, @rtp, @rtcp);
	# XXX support rtcp-mux and rtcp-less media

        my $rtp = IO::Socket::IP->new(Type => &SOCK_DGRAM, Proto => 'udp',
                                      LocalHost => $address->{address}, LocalPort => $port)
            or die("Failed to set up RTP client socket: $address->{address}:${port}: $!");
        $port++;
        my $rtcp = IO::Socket::IP->new(Type => &SOCK_DGRAM, Proto => 'udp',
                                       LocalHost => $address->{address}, LocalPort => $port)
            or die("Failed to set up RTCP client socket: $address->{address}:$parent->{media_port}: $!");
        $port++;

        push(@sockets, [$rtp, $rtcp]); # component 0 and 1
        push(@rtp, $rtp);
        push(@rtcp, $rtcp);
        $parent->{mux}->add($rtp);
        $parent->{mux}->add($rtcp);
        $parent->{mux}->set_timeout($rtp, 0.01); # XXX overkill, only need this on one

	@sockets or die;

	$self->{sockets} = \@sockets;
	$self->{rtp_sockets} = \@rtp;
	$self->{rtcp_sockets} = \@rtcp;

	$self->{main_sockets} = $sockets[0]; # for m= and o=
	$self->{local_sdp} = NGCP::Rtpclient::SDP->new($self->{main_sockets}->[0]); # no global c=
	$self->{component_peers} = []; # keep track of peer source addresses

	# default protocol
	my $proto = 'RTP/AVP';
	$args{sdes} and $proto = 'RTP/SAVP';
	$args{dtls} and $proto = 'UDP/TLS/RTP/SAVP';
	$args{protocol} and $proto = $args{protocol};

	$self->{local_media} = $self->{local_sdp}->add_media(NGCP::Rtpclient::SDP::Media->new(
		$self->{main_sockets}->[0], $self->{main_sockets}->[1], # main rtp and rtcp
		protocol => $proto,
		codecs => $self->{codecs},
	));
	# XXX support multiple medias

	if ($args{sdes}) {
		$self->{sdes} = NGCP::Rtpclient::SDES->new(%{$args{sdes_args}});
	}
	if ($args{dtls}) {
		$self->{dtls} = NGCP::Rtpclient::DTLS::Group->new($parent->{mux}, $self, [ \@rtp, \@rtcp ]);
		$self->{local_media}->add_attrs($self->{dtls}->encode());
		$self->{dtls}->accept(); # XXX support other modes
	}
	if ($args{ice}) {
		$self->{ice} = NGCP::Rtpclient::ICE->new(2, 1); # 2 components, controlling XXX
		my $pref = 65535;
		for my $s (@sockets) {
			$self->{ice}->add_candidate($pref--, 'host', @$s); # 2 components
		}
		$self->{local_media}->add_attrs($self->{ice}->encode());
	}

	$self->{media_receive_queues} = [[],[]]; # for each component
	$self->{media_packets_sent} = [0,0];
	$self->{media_packets_received} = [0,0];
	$self->{media_packets_lost} = [0,0];
	$self->{client_components} = [undef,undef];

	$self->{args} = \%args;

	# copy args for the RTP client
	$self->{rtp_args} = {};
	for my $k (qw(packetloss)) {
		exists($args{$k}) or next;
		$self->{rtp_args}->{$k} = $args{$k};
	}

	return $self;
}

sub media_receiver {
	my ($self, $other) = @_;
	$self->{media_receiver} = $other;
}

sub media_to_receive {
	my ($self, $component, $s) = @_;
	push(@{$self->{media_receive_queues}->[$component]}, $s);
}

sub _packet_send {
	my ($self, $component, $s) = @_;

	my $local_socket = $self->{main_sockets}->[$component];

	my $dest;

	if (!$self->{ice}) {
		if ($self->{remote_media}) {
			$dest = $component == 0 ? $self->{remote_media}->endpoint()
				: $self->{remote_media}->rtcp_endpoint();
		}
		else {
			$dest = $self->{component_peers}->[$component]
		}
	}
	else {
		($local_socket, $dest) = $self->{ice}->get_send_component($component);
	}

	if ($self->{srtp}) {
		$s = $self->{srtp}->encrypt($component, $s);
	}

	$local_socket->send($s, 0, $dest);
}

sub _media_send {
	my ($self, $component, $s) = @_;
	$self->_packet_send($component, $s);
	$self->{media_packets_sent}->[$component]++;

	my $local_socket = $self->{main_sockets}->[$component];
        my $local_addr = $local_socket->sockhost . ":" . $local_socket->sockport;
        my $peer_addr  = $local_socket->peerhost . ":" . $local_socket->peerport;
        print __PACKAGE__ . "::_media_send: $local_addr -> $peer_addr, component $component: <" .
            unpack('H*', $s) . ">\n";
	$self->{media_receiver} and $self->{media_receiver}->media_to_receive($component, $s);
}

sub dtls_send {
	my ($self, $component, $s) = @_;
	$self->_packet_send($component, $s);
}
sub rtp_send {
	my ($self, $s) = @_;
	$self->_media_send(0, $s);
}
sub rtcp_send {
	my ($self, $s) = @_;
	$self->_media_send(1, $s);
}


sub _default_req_args {
	my ($self, $cmd, %args) = @_;

	my $req = { command => $cmd, 'call-id' => $self->{parent}->{callid} };

	for my $cp (qw(sdp from-tag to-tag ICE transport-protocol address-family label direction codec)) {
		$args{$cp} and $req->{$cp} = $args{$cp};
	}
	for my $cp (@{$args{flags}}) {
		push(@{$req->{flags}}, $cp);
	}

	return $req;
}

sub offer {
	my ($self, $other, %args) = @_;

	$self->{sdes} and $self->{local_media}->add_attrs($self->{sdes}->encode());
	my $sdp_body = $self->{local_sdp}->encode();
	# XXX validate SDP

	my $req = $self->_default_req_args('offer', 'from-tag' => $self->{tag}, sdp => $sdp_body, %args);

	my $out = $self->{parent}->{control}->req($req);

	$other->_offered($out);
}

sub _offered {
	my ($self, $req) = @_;

	my $sdp_body = $req->{sdp} or die;
	$self->{remote_sdp_raw} = $sdp_body;
	$self->{remote_sdp} = NGCP::Rtpclient::SDP->decode($sdp_body);
	# XXX validate SDP
	@{$self->{remote_sdp}->{medias}} == 1 or die;
	$self->{remote_media} = $self->{remote_sdp}->{medias}->[0];
	$self->{local_sdp}->codec_negotiate($self->{remote_sdp});
	if ($self->{sdes}) {
		$self->{sdes}->decode($self->{remote_media});
		$self->{sdes}->offered();
		$self->{srtp} = NGCP::Rtpclient::SRTP::Context->new($self->{sdes}->{suite});
	}
	$self->{ice} and $self->{ice}->decode($self->{remote_media}->decode_ice());
}

sub answer {
	my ($self, $other, %args) = @_;

	$self->{sdes} and $self->{local_media}->add_attrs($self->{sdes}->encode());
	my $sdp_body = $self->{local_sdp}->encode();
	# XXX validate SDP

	my $req = $self->_default_req_args('answer', 'from-tag' => $other->{tag}, 'to-tag' => $self->{tag},
		sdp => $sdp_body, %args);

	my $out = $self->{parent}->{control}->req($req);

	$other->_answered($out);
}

sub _answered {
	my ($self, $req) = @_;

	my $sdp_body = $req->{sdp} or die;
	$self->{remote_sdp_raw} = $sdp_body;
	$self->{remote_sdp} = NGCP::Rtpclient::SDP->decode($sdp_body);
	# XXX validate SDP
	@{$self->{remote_sdp}->{medias}} == 1 or die;
	$self->{remote_media} = $self->{remote_sdp}->{medias}->[0];
	$self->{local_sdp}->codec_negotiate($self->{remote_sdp});
	if ($self->{sdes}) {
		$self->{sdes}->decode($self->{remote_media});
		$self->{sdes}->answered();
		$self->{srtp} = NGCP::Rtpclient::SRTP::Context->new($self->{sdes}->{suite});
	}
	$self->{ice} and $self->{ice}->decode($self->{remote_media}->decode_ice());
}

sub teardown {
	my ($self, %args) = @_;

	my $req = $self->_default_req_args('delete', 'from-tag' => $self->{tag}, %args);

	my $out = $self->{parent}->{control}->req($req);

	if ($args{dump}) {
		my $dumper = Data::Dumper->new([$out]);
		$dumper->Sortkeys(1);
		print($dumper->Dump);
	}

	return $out;
}

sub _input {
	my ($self, $fh, $input, $peer) = @_;

	my $component = $self->_peer_addr_check($fh, $peer);

	$self->{dtls} and $self->{dtls}->input($fh, $input, $peer);
	$self->{ice} and $self->{ice}->input($fh, $input, $peer);

	$$input eq '' and return;

	defined($component) or return; # not one of ours

	# must be RTP or RTCP input
        my $local_addr = $fh->sockhost . ":" . $fh->sockport;
        my $peer_addr  = $fh->peerhost . ":" . $fh->peerport;
        print __PACKAGE__ . "::_input: Received packet: $peer_addr -> $local_addr, component $component: <" .
            unpack('H*', $$input) . ">\n";

        # RG: omit RTCP
	if ($component == 0 && !$self->{args}->{no_data_check}) {
		if ($self->{srtp}) {
			$$input = $self->{srtp}->decrypt($component, $$input);
		}

		my $exp = shift(@{$self->{media_receive_queues}->[$component]});
                if($exp){
                    if($$input eq $exp){
                        print __PACKAGE__ . "::_input: Payload OK: $peer_addr -> $local_addr, component $component: <" .
                            unpack('H*', $exp) . ">\n";
                    } else{
                        warn "WARNING: Received payload does not match the payload expected for " .
                            "$peer_addr -> $local_addr, component $component:\n" .
                            "  Received: <" . unpack('H*', $$input)
                            . '>\n  Expected: <' . unpack('H*', $exp) . ">";

                        # we've lost a packet or two, got out of sync, try to re-sync
                        while($exp = shift(@{$self->{media_receive_queues}->[$component]})){
                            $self->{media_packets_lost}[$component]++;
                            $$input eq $exp and last;
                        }

                        $$input = '';
                        return;
                    }
                } else {
                    warn __PACKAGE__ . "::_input: media_receive_queues empty for " .
                        "$peer_addr -> $local_addr, component $component:\n";
                    $$input = '';
                    return;
                }
            }
	else {
		@{$self->{media_receive_queues}->[$component]} = ();
	}
	$self->{media_packets_received}->[$component]++;

	$self->{client_components}->[$component] and
		$self->{client_components}->[$component]->input($$input);

	$$input = '';
}

sub _timer {
	my ($self) = @_;
	$self->{ice} and $self->{ice}->timer();
	$self->{rtp} and $self->{rtp}->timer();
	$self->{rtcp} and $self->{rtcp}->timer();
}

sub _peer_addr_check {
	my ($self, $fh, $peer) = @_;

	for my $sockets (@{$self->{sockets}}) {
		for my $component (0, 1) {
			if ($fh == $sockets->[$component]) {
				$self->{component_peers}->[$component] = $peer;
				return $component;
			}
		}
	}

	return;
}

sub start_rtp {
	my ($self) = @_;
	$self->{rtp} and die;
	my %args = %{$self->{rtp_args}};
	my $send_codec = $self->{local_media}->send_codec();
	$args{send_codec} = $send_codec;
	$self->{rtp} = NGCP::Rtpclient::RTP->new($self, %args) or die;
	$self->{client_components}->[0] = $self->{rtp};
}

sub start_rtcp {
	my ($self) = @_;
	$self->{rtcp} and die;
	$self->{rtcp} = NGCP::Client::RTCP->new($self, $self->{rtp}) or die;
	$self->{client_components}->[1] = $self->{rtcp};
}

sub stop {
	my ($self) = @_;
	print("media packets sent: @{$self->{media_packets_sent}}\n");
	print("media packets received: @{$self->{media_packets_received}}\n");
	print("media packets lost: @{$self->{media_packets_lost}}\n");
	my @queues = map {scalar(@$_)} @{$self->{media_receive_queues}};
	print("media packets outstanding: @queues\n");
}

sub remote_codecs {
	my ($self) = @_;
	my $list = $self->{remote_media}->{codec_list};
	return join(',', map {"$_->{name}/$_->{clockrate}/$_->{channels}"} @$list);
}

sub send_codecs {
	my ($self) = @_;
	my $list = $self->{local_media}->{codecs_send};
	return join(',', map {"$_->{name}/$_->{clockrate}/$_->{channels}"} @$list);
}

1;

