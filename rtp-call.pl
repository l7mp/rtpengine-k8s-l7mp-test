#!/usr/bin/perl

use strict;
use warnings;
use feature qw/:all/;

use IO::All;
use IO::Socket;
use Data::Dumper;
# $Data::Dumper::Deepcopy=1;
$Data::Dumper::Indent=1;

use Getopt::Long;
use Pod::Usage;

use NGCP::Rtpengine::Client;

my $rtpengine_host    = '127.0.0.1';
my $rtpengine_ng_port = 22222;
my $local_ip_a        = '127.0.0.1';
my $remote_ip_a       = undef;
my $local_rtp_port_a  = 10000;
my $local_ip_b        = '127.0.0.1';
my $remote_ip_b       = undef;
my $local_rtp_port_b  = 10002;
my $yaml_file         = '/tmp/rtp-config.yaml';
my $no_k8s            = 0;
my $holding_time      = 30;
my $no_rtp            = 0;
my($man, $help, $verbose);

GetOptions(
    'rtpengine-host|r=s'         => \$rtpengine_host,
    'rtpengine-control-port|p=i' => \$rtpengine_ng_port,
    'local-ip-a=s'               => \$local_ip_a,
    'remote-ip-a=s'              => \$remote_ip_a,
    'local-rtp-port-a=i'         => \$local_rtp_port_a,
    'local-ip-b=s'               => \$local_ip_b,
    'remote-ip-b=s'              => \$remote_ip_b,
    'local-rtp-port-b=i'         => \$local_rtp_port_b,
    'holding-time|t=i'           => \$holding_time,
    'no-rtp|n'                   => \$no_rtp,
    'no-k8s|n'                   => \$no_k8s,
    'verbose|v+'                 => \$verbose,
    'help|?'                     => \$help,
    'man'                        => \$man,
) or pod2usage(2);

pod2usage(1) if $help;
pod2usage(-exitstatus => 0, -verbose => 2) if $man;

# INIT RTP CALL

my $local_rtcp_port_a = $local_rtp_port_a + 1;
my $local_rtcp_port_b = $local_rtp_port_b + 1;

my $r = NGCP::Rtpengine::Call->new(
    host => $rtpengine_host,
    port => $rtpengine_ng_port,
    no_data_check => 1
);
my $callid = $r->{callid};

my $a = $r->client(sockdomain => &Socket::AF_INET, address => {address => $local_ip_a}, port => $local_rtp_port_a);
my $b = $r->client(sockdomain => &Socket::AF_INET, address => {address => $local_ip_b}, port => $local_rtp_port_b);
$a->{media_receiver} = $b;
$b->{media_receiver} = $a;

$a->offer($b,  ICE => 'remove', 'media address' => '127.0.0.1', label => "caller");
$b->answer($a, ICE => 'remove', 'media address' => '127.0.0.1', label => "callee");

my $tag_a = $a->{tag};
my $remote_media_a = $a->{remote_media};
if(defined $remote_ip_a){
    $remote_media_a->{connection}{address} = $remote_ip_a;
} else {
    $remote_ip_a = $remote_media_a->{connection}{address};
}
my $remote_rtp_port_a  = $remote_media_a->{port};
my $remote_rtcp_port_a = $remote_media_a->{rtcp_port};

say "Caller connection: RTP: ${local_ip_a}:${local_rtp_port_a} -> ${remote_ip_a}:${remote_rtp_port_a} / RTCP: ${local_ip_a}:${local_rtcp_port_a} -> ${remote_ip_a}:${remote_rtcp_port_a}";

my $tag_b = $b->{tag};
my $remote_media_b = $b->{remote_media};
if(defined $remote_ip_b){
    $remote_media_b->{connection}{address} = $remote_ip_b;
} else {
    $remote_ip_b = $remote_media_b->{connection}{address};
}
my $remote_rtp_port_b  = $remote_media_b->{port};
my $remote_rtcp_port_b = $remote_media_b->{rtcp_port};

say "Callee connection: RTP: ${local_ip_b}:${local_rtp_port_b} -> ${remote_ip_b}:${remote_rtp_port_b} / RTCP: ${local_ip_b}:${local_rtcp_port_b} -> ${remote_ip_b}:${remote_rtcp_port_b}";

$r->timer_once($holding_time, sub {
                   print "Press ENTER to delete call:";
                   <STDIN>;

                   $r->stop();
                   unless($no_k8s){
                       system("kubectl delete -f $yaml_file");
                       $? == -1 and die "failed to execute kubectl: $!\n";
                   }
               });

unless($no_k8s){
    # INIT L7MP
    my $yaml = join("", <main::DATA>);
    # variable substitution
    $yaml =~ s/(\$\{\w+\})/$1/eeg;          # finds my() variables
    $yaml > io($yaml_file);

    system("kubectl apply -f $yaml_file");
    $? == -1 and die "failed to execute kubectl: $!\n";
    sleep(5);
}

# START RTP/RTCP

unless($no_rtp){
    $a->start_rtp();
    $a->start_rtcp();
    $b->start_rtp();
    $b->start_rtcp();
}

$r->run();

$a->teardown(dump => 1);

1;

=head1 NAME

  rtp-call - Start an RTP call

=head1 SYNOPSIS

  rtp-call [--rtpengine-host|-r] [--rtpengine-control-port|-p] \
           [--local-ip-a] [--local-rtp-port-a] \
           [--local-ip-b] [--local-rtp-port-b]

=head1 DESCRIPTION

Start an RTP call via the given rtp-proxy.

=head1 OPTIONS

=over 8

=item B<--rtpengine-host|-r>

Rtpengine control channel IP.

=item B<--rtpengine-control-port|-p>

Rtpengine control channel port.

=item B<--local-ip-a>

Force local IP for caller.

=item B<--remote-ip-a>

Force remote IP for caller, override whatever was send by rtpengine.

=item B<--local-rtp-port-a>

Force local port for caller.

=item B<--local-ip-b>

Force local IP for callee.

=item B<--remote-ip-b>

Force remote IP for callee, override whatever was send by rtpengine.

=item B<--local-rtp-port-b>

Force local port for callee.

=item B<-v|--verbose>

=item B<-help>

=item B<-man>

=back

=cut

__DATA__

# RTP: A

apiVersion: l7mp.io/v1
kind: VirtualService
metadata:
  name: "ingress-rtp-vsvc-${callid}-${tag_a}"
spec:
  updateOwners: True
  selector:
    matchLabels:
      app: l7mp-ingress
  listener:
    spec:
      UDP:
        port: ${remote_rtp_port_a}
        connect: { address: ${local_ip_a}, port: ${local_rtp_port_a} }
        options:
          mode: server
    rules:
      - action:
          rewrite:
            - path: "/labels/callid"
              valueStr: "${callid}"
            - path: "/labels/tag"
              valueStr: ${tag_a}
          route:
            destinationRef: "/apis/l7mp.io/v1/namespaces/default/targets/ingress-rtp-target-${callid}-${tag_a}"
            retry:
              retry_on: always
              num_retries: 1000
              timeout: 2000
    options:
      track: 600

---

apiVersion: l7mp.io/v1
kind: Target
metadata:
  name: "ingress-rtp-target-${callid}-${tag_a}"
spec:
  selector:
    matchLabels:
      app: l7mp-ingress
  cluster:
    spec:
      JSONSocket:
        transport:
          UDP:
            port: 19000
        header:
          - path: { from: "/labels", to: "/labels" }
    endpoints:
      - selector:
          matchLabels:
            app: l7mp-worker
    loadbalancer:
      policy: ConsistentHash
      key: "/labels/callid"

---

apiVersion: l7mp.io/v1
kind: Rule
metadata:
  name: "worker-rtp-rule-${callid}-${tag_a}"
spec:
  updateOwners: True
  selector:
    matchLabels:
      app: l7mp-worker
  position: 0
  rulelist: worker-rtp-rulelist
  rule:
    match:
      op: and
      apply:
        - op: test
          path: '/JSONSocket/labels/callid'
          value: "${callid}"
        - op: test
          path: '/JSONSocket/labels/tag'
          value: "${tag_a}"
    action:
      route:
        destination:
          spec:
            UDP:
              port: ${remote_rtp_port_a}
              bind:
                address: '127.0.0.1'
                port: ${local_rtp_port_a}
          endpoints:
            - spec: { address: "127.0.0.1" }
        ingress:
          - clusterRef: "ingress-metric-counter"
        egress:
          - clusterRef: "egress-metric-counter"
        retry:
          retry_on: always
          num_retries: 5
          timeout: 200

---

# RTP: B

apiVersion: l7mp.io/v1
kind: VirtualService
metadata:
  name: "ingress-rtp-vsvc-${callid}-${tag_b}"
spec:
  updateOwners: True
  selector:
    matchLabels:
      app: l7mp-ingress
  listener:
    spec:
      UDP:
        port: ${remote_rtp_port_b}
        connect: { address: ${local_ip_b}, port: ${local_rtp_port_b} }
        options:
          mode: server
    rules:
      - action:
          rewrite:
            - path: "/labels/callid"
              valueStr: "${callid}"
            - path: "/labels/tag"
              valueStr: ${tag_b}
          route:
            destinationRef: "/apis/l7mp.io/v1/namespaces/default/targets/ingress-rtp-target-${callid}-${tag_b}"
            retry:
              retry_on: always
              num_retries: 1000
              timeout: 2000
    options:
      track: 600

---

apiVersion: l7mp.io/v1
kind: Target
metadata:
  name: "ingress-rtp-target-${callid}-${tag_b}"
spec:
  selector:
    matchLabels:
      app: l7mp-ingress
  cluster:
    spec:
      JSONSocket:
        transport:
          UDP:
            port: 19000
        header:
          - path: { from: "/labels", to: "/labels" }
    endpoints:
      - selector:
          matchLabels:
            app: l7mp-worker
    loadbalancer:
      policy: ConsistentHash
      key: "/labels/callid"

---

apiVersion: l7mp.io/v1
kind: Rule
metadata:
  name: "worker-rtp-rule-${callid}-${tag_b}"
spec:
  updateOwners: True
  selector:
    matchLabels:
      app: l7mp-worker
  position: 0
  rulelist: worker-rtp-rulelist
  rule:
    match:
      op: and
      apply:
        - op: test
          path: '/JSONSocket/labels/callid'
          value: "${callid}"
        - op: test
          path: '/JSONSocket/labels/tag'
          value: "${tag_b}"
    action:
      route:
        destination:
          spec:
            UDP:
              port: ${remote_rtp_port_b}
              bind:
                address: '127.0.0.1'
                port: ${local_rtp_port_b}
          endpoints:
            - spec: { address: "127.0.0.1" }
        ingress:
          - clusterRef: "ingress-metric-counter"
        egress:
          - clusterRef: "egress-metric-counter"
        retry:
          retry_on: always
          num_retries: 5
          timeout: 200

---

# RTCP: A

apiVersion: l7mp.io/v1
kind: VirtualService
metadata:
  name: "ingress-rtcp-vsvc-${callid}-${tag_a}"
spec:
  updateOwners: True
  selector:
    matchLabels:
      app: l7mp-ingress
  listener:
    spec:
      UDP:
        port: ${remote_rtcp_port_a}
        connect: { address: ${local_ip_a}, port: ${local_rtcp_port_a} }
        options:
          mode: server
    rules:
      - action:
          rewrite:
            - path: "/labels/callid"
              valueStr: "${callid}"
            - path: "/labels/tag"
              valueStr: ${tag_a}
          route:
            destinationRef: "/apis/l7mp.io/v1/namespaces/default/targets/ingress-rtcp-target-${callid}-${tag_a}"
            retry:
              retry_on: always
              num_retries: 1000
              timeout: 2000
    options:
      track: 600

---

apiVersion: l7mp.io/v1
kind: Target
metadata:
  name: "ingress-rtcp-target-${callid}-${tag_a}"
spec:
  selector:
    matchLabels:
      app: l7mp-ingress
  cluster:
    spec:
      JSONSocket:
        transport:
          UDP:
            port: 19001
        header:
          - path: { from: "/labels", to: "/labels" }
    endpoints:
      - selector:
          matchLabels:
            app: l7mp-worker
    loadbalancer:
      policy: ConsistentHash
      key: "/labels/callid"

---

apiVersion: l7mp.io/v1
kind: Rule
metadata:
  name: "worker-rtcp-rule-${callid}-${tag_a}"
spec:
  updateOwners: True
  selector:
    matchLabels:
      app: l7mp-worker
  position: 0
  rulelist: worker-rtcp-rulelist
  rule:
    match:
      op: and
      apply:
        - op: test
          path: '/JSONSocket/labels/callid'
          value: "${callid}"
        - op: test
          path: '/JSONSocket/labels/tag'
          value: "${tag_a}"
    action:
      route:
        destination:
          spec:
            UDP:
              port: ${remote_rtcp_port_a}
              bind:
                address: '127.0.0.1'
                port: ${local_rtcp_port_a}
          endpoints:
            - spec: { address: "127.0.0.1" }
        retry:
          retry_on: always
          num_retries: 5
          timeout: 200

---

# RTCP: B

apiVersion: l7mp.io/v1
kind: VirtualService
metadata:
  name: "ingress-rtcp-vsvc-${callid}-${tag_b}"
spec:
  updateOwners: True
  selector:
    matchLabels:
      app: l7mp-ingress
  listener:
    spec:
      UDP:
        port: ${remote_rtcp_port_b}
        connect: { address: ${local_ip_b}, port: ${local_rtcp_port_b} }
        options:
          mode: server
    rules:
      - action:
          rewrite:
            - path: "/labels/callid"
              valueStr: "${callid}"
            - path: "/labels/tag"
              valueStr: ${tag_b}
          route:
            destinationRef: "/apis/l7mp.io/v1/namespaces/default/targets/ingress-rtcp-target-${callid}-${tag_b}"
            retry:
              retry_on: always
              num_retries: 1000
              timeout: 2000
    options:
      track: 600

---

apiVersion: l7mp.io/v1
kind: Target
metadata:
  name: "ingress-rtcp-target-${callid}-${tag_b}"
spec:
  selector:
    matchLabels:
      app: l7mp-ingress
  cluster:
    spec:
      JSONSocket:
        transport:
          UDP:
            port: 19001
        header:
          - path: { from: "/labels", to: "/labels" }
    endpoints:
      - selector:
          matchLabels:
            app: l7mp-worker
    loadbalancer:
      policy: ConsistentHash
      key: "/labels/callid"

---

apiVersion: l7mp.io/v1
kind: Rule
metadata:
  name: "worker-rtcp-rule-${callid}-${tag_b}"
spec:
  updateOwners: True
  selector:
    matchLabels:
      app: l7mp-worker
  position: 0
  rulelist: worker-rtcp-rulelist
  rule:
    match:
      op: and
      apply:
        - op: test
          path: '/JSONSocket/labels/callid'
          value: "${callid}"
        - op: test
          path: '/JSONSocket/labels/tag'
          value: "${tag_b}"
    action:
      route:
        destination:
          spec:
            UDP:
              port: ${remote_rtcp_port_b}
              bind:
                address: '127.0.0.1'
                port: ${local_rtcp_port_b}
          endpoints:
            - spec: { address: "127.0.0.1" }
        retry:
          retry_on: always
          num_retries: 5
          timeout: 200
