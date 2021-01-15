# A test suite for the rtpenegine Kubernetes/l7mp.io integration

This will initialize a local minikube Kubernetes install with all the bells and whistles to run rtpengine over the l7mp service mesh, start a call, and dump connection statistics as collected with RTCP. Should be a good start for any project aiming to build a telco use case on top of l7mp.

## Getting started

Install dependencies:

``` sh
sudo apt-get install libcrypt-openssl-rsa-perl libcrypt-rijndael-perl libdigest-crc-perl libdigest-hmac-perl libio-multiplex-perl libnet-interface-perl libbencode-perl libsocket6-perl libio-all-perl kubectl
sudo apt-get install qemu-system libvirt-clients libvirt-daemon-system
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube_latest_amd64.deb
sudo dpkg -i minikube_latest_amd64.deb
```

Start `minikube`:

``` sh
minikube start --driver kvm2 --cpus 4 --memory 16384 
eval $(minikube docker-env)
```

Clone `rtpengine`, `l7mp`, and the k8s/l7mp test suite:

``` sh
git clone https://github.com/sipwise/rtpengine.git
export RTPENGINE_DIR=$(pwd)/rtpengine
git clone https://github.com/l7mp/l7mp.git
git clone https://github.com/l7mp/l7mp/rtpengine-k8s-l7mp-test
```

Build the latest l7mp proxy locally (may need this to use some unstable features) and fire up the operator+gateway:

``` sh
cd l7mp
git reset --hard HEAD
docker build -t l7mp/l7mp:0.5.7 -t l7mp/l7mp:latest .
helm install --set l7mpProxyImage.pullPolicy=Never l7mp/l7mp-ingress --generate-name 
cd ..
```

Install the worker, fire up rtpengine at each worker pod (note that the local rtpengine build is _not_ used, rather the `drachtio/rtpengine` container image is loaded; this can be set to an arbitrary image in `kubernetes/rtpengine-worker.yaml`), and init the l7mp service mesh: 

``` sh
cd rtpengine-k8s-l7mp-test
kubectl apply -f kubernetes/rtpengine-worker.yaml 
```

Find out your local IP to the `minikube` VM (the below works most of the time):

``` sh
export LOCAL_IP=$(echo $(minikube ip) | sed 's/\([0-9]\+\)$/1/')
```


## Make a test call

``` sh
perl -I. -I../${RTPENGINE_DIR}/perl/ rtp-call.pl \
    --rtpengine-host=$(minikube ip) --rtpengine-control-port=22222 \
    --local-ip-a=${LOCAL_IP} --local-ip-b=${LOCAL_IP} \
    --local-rtp-port-a=10000 --local-rtp-port-b=10002 \
    --remote-ip-a=$(minikube ip) --remote-ip-b=$(minikube ip)
```


## What's going on here?

Here is the list of things the Perl script does:

1. Use the NGC Perl client from the rtpengine distro to init an control channel to rtpengine:

``` perl
my $r = NGCP::Rtpengine::Call->new(
    host => $rtpengine_host,
    port => $rtpengine_ng_port,
    no_data_check => 1
);
my $callid = $r->{callid};
```

2. Make two RTP endpoints, the caller `a` and the callee `b`, and set up `b` as the media receiver for `a`, and vice versa:

``` perl
my $a = $r->client(sockdomain => &Socket::AF_INET, 
    address => {address => $local_ip_a}, port => $local_rtp_port_a);
my $b = $r->client(sockdomain => &Socket::AF_INET, 
    address => {address => $local_ip_b}, port => $local_rtp_port_b);
$a->{media_receiver} = $b;
$b->{media_receiver} = $a;
```

3. Send an `offer` from `a` and an `answer` from `b`:

``` perl
$a->offer($b,  ICE => 'remove', 'media address' => '127.0.0.1', label => "caller");
$b->answer($a, ICE => 'remove', 'media address' => '127.0.0.1', label => "callee");
```

4. Set a timeout at `$holding_time` to delete the call:

``` perl
$r->timer_once($holding_time, sub {
                   $r->stop();
               });
```

5. Init the l7mp virtualservices and targets (see the inline template in `rtp-call.pl`:

For user `a` (caller), RTP:

* `ingress-rtp-vsvc-${callid}-${tag_a}`: User-A facing RTP receive socket at the ingress gateway(s)
* `ingress-rtp-target-${callid}-${tag_a}`: User-A RTP route from the ingress gateway(s) to the worker(s)
* `worker-rtp-rule-${callid}-${tag_a}`: User-A RTP connection routing rule at the worker(s)

For user `b` (callee), RTP:

* `ingress-rtp-vsvc-${callid}-${tag_b}`: User-B facing RTP receive socket at the ingress gateway(s)
* `ingress-rtp-target-${callid}-${tag_b}`: User-B RTP route from the ingress gateway(s) to the worker(s)
* `worker-rtp-rule-${callid}-${tag_b}`: User-B RTP connection routing rule at the worker(s)

For user `a` (caller), RTCP:

* `ingress-rtcp-vsvc-${callid}-${tag_a}`: User-A facing RTCP receive socket at the ingress gateway(s)
* `ingress-rtcp-target-${callid}-${tag_a}`: User-A RTCP route from the ingress gateway(s) to the worker(s)
* `worker-rtcp-rule-${callid}-${tag_a}`: User-A RTCP connection routing rule at the worker(s)

For user `b` (callee), RTCP:

* `ingress-rtcp-vsvc-${callid}-${tag_b}`: User-B facing RTCP receive socket at the ingress gateway(s)
* `ingress-rtcp-target-${callid}-${tag_b}`: User-B RTCP route from the ingress gateway(s) to the worker(s)
* `worker-rtcp-rule-${callid}-${tag_b}`: User-B RTCP connection routing rule at the worker(s)


## Caveats

* We predictably lose the first 2-3 RTP/UDP packets from the callee back to the caller. This is because the l7mp gateway VirtualServices run in `server` mode, i.e., "on-demand" upon the reception of the first packet, and it just so happens from time to time that the callee starts first and this somehow creates the above effect. /Fix:/ switch the l7mp proxies to `connected` mode (not tested).
* The client address in the `offer` and the `answer` is currently the original user local IP, i.e., `$LOCAL_IP`, which is not correct because the rtpengine instance receive the RTP packets from the sidecar l7mp proxy on the loopback interface, rather than from the original source IP address of the user. FIX: rewrite `offer` and the `answer` client addresses to `127.0.0.1` (not tested).
* We need to init 6 separate l7mp resources for each call (3 for the caller and 3 for the callee). /Fix:/ we can bring this down to 4 with inlining the ingress gateway Target `ingress-rtp/rtcp-target-*` into the VirtualService `ingress-rtp/rtcp-vsvc-*` (check if this s supported in the operator), but this still seems too many. Idea: resurrect the session operator?
* RTP packets are send with random payload. This is good for testing (easy to find lost packets) and it works like charm insofar as rtpengine doesn't need transcoding and repacketization. /Fix:/ change the RTP client code to send prerecorded streams (or use `ffmpeg`).
* rtpengine `iptables` offload ("kernelization") is not enabled. /Fix:/ deploy the iptables module into the worker Kubernetes nodes and grant the rtpengine container access to the host `iptables` facilities (note sure how to do this, but if this works then rtpengine should automatically start to use the offload engine for suitable calls).

## TODO

* rtpengine runs without transcoding (pure proxy mode), which is fine but kinda defeats the whole purpose of scaling; for demoing scaling we need a workload that stresses the CPUs and transcoding is exactly this type of workload. /Fix:/ configure the caller and the calle so that rtpengine will need to do transcoding.
* We'd need multiple workers to test resiliency. /Fix:/ rewrite the worker deployment manifest in `kubernetes/rtpengine-worker.yaml` (should work). Note: Redis needs to be installed and set up separately, this project does not do that.
* We'd need multiple workers to test scaling. /Fix:/ rewrite the worker deployment manifest in `kubernetes/rtpengine-worker.yaml` (should work). 
* l7mp kernel offload is not enabled. /Fix:/ finish and release kernel offload to l7mp.

## License

Distributed under the MIT License. See `LICENSE` for more information.

## Contact

* [The l7mp.io project](https://l7mp.io)
