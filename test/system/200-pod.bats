#!/usr/bin/env bats

load helpers

# This is a long ugly way to clean up pods and remove the pause image
function teardown() {
    run_podman pod rm -f -t 0 -a
    run_podman rm -f -t 0 -a
    run_podman image list --format '{{.ID}} {{.Repository}}'
    while read id name; do
        if [[ "$name" =~ /podman-pause ]]; then
            run_podman rmi $id
        fi
    done <<<"$output"

    basic_teardown
}


@test "podman pod - basic tests" {
    run_podman pod list --noheading
    is "$output" "" "baseline: empty results from list --noheading"

    run_podman pod ls --noheading
    is "$output" "" "baseline: empty results from ls --noheading"

    run_podman pod ps --noheading
    is "$output" "" "baseline: empty results from ps --noheading"
}

@test "podman pod top - containers in different PID namespaces" {
    # With infra=false, we don't get a /pause container (we also
    # don't pull k8s.gcr.io/pause )
    no_infra='--infra=false'
    run_podman pod create $no_infra
    podid="$output"

    # Start two containers...
    run_podman run -d --pod $podid $IMAGE top -d 2
    cid1="$output"
    run_podman run -d --pod $podid $IMAGE top -d 2
    cid2="$output"

    # ...and wait for them to actually start.
    wait_for_output "PID \+PPID \+USER " $cid1
    wait_for_output "PID \+PPID \+USER " $cid2

    # Both containers have emitted at least one top-like line.
    # Now run 'pod top', and expect two 'top -d 2' processes running.
    run_podman pod top $podid
    is "$output" ".*root.*top -d 2.*root.*top -d 2" "two 'top' containers"

    # By default (podman pod create w/ default --infra) there should be
    # a /pause container.
    if [ -z "$no_infra" ]; then
        is "$output" ".*0 \+1 \+0 \+[0-9. ?s]\+/pause" "there is a /pause container"
    fi

    # Clean up
    run_podman pod rm -f -t 0 $podid
}


@test "podman pod create - custom infra image" {
    skip_if_remote "CONTAINERS_CONF only effects server side"
    image="i.do/not/exist:image"
    tmpdir=$PODMAN_TMPDIR/pod-test
    run mkdir -p $tmpdir
    containersconf=$tmpdir/containers.conf
    cat >$containersconf <<EOF
[engine]
infra_image="$image"
EOF

    run_podman 125 pod create --infra-image $image
    is "$output" ".*initializing source docker://$image:.*"

    CONTAINERS_CONF=$containersconf run_podman 125 pod create
    is "$output" ".*initializing source docker://$image:.*"

    CONTAINERS_CONF=$containersconf run_podman 125 create --pod new:test $IMAGE
    is "$output" ".*initializing source docker://$image:.*"
}

@test "podman pod - communicating between pods" {
    podname=pod$(random_string)
    run_podman 1 pod exists $podname
    run_podman pod create --infra=true --name=$podname
    podid="$output"
    run_podman pod exists $podname
    run_podman pod exists $podid

    # (Assert that output is formatted, not a one-line blob: #8021)
    run_podman pod inspect $podname
    if [[ "${#lines[*]}" -lt 10 ]]; then
        die "Output from 'pod inspect' is only ${#lines[*]} lines; see #8011"
    fi

    # Randomly-assigned port in the 5xxx range
    port=$(random_free_port)

    # Listener. This will exit as soon as it receives a message.
    run_podman run -d --pod $podname $IMAGE nc -l -p $port
    cid1="$output"

    # (While we're here, test the 'Pod' field of 'podman ps'. Expect two ctrs)
    run_podman ps --format '{{.Pod}}'
    newline="
"
    is "$output" "${podid:0:12}${newline}${podid:0:12}" "ps shows 2 pod IDs"

    # Talker: send the message via common port on localhost
    message=$(random_string 15)
    run_podman run --rm --pod $podname $IMAGE \
               sh -c "echo $message | nc 127.0.0.1 $port"

    # Back to the first (listener) container. Make sure message was received.
    run_podman logs $cid1
    is "$output" "$message" "message sent from one container to another"

    # Clean up. First the nc -l container...
    run_podman rm $cid1

    # ...then rm the pod, then rmi the pause image so we don't leave strays.
    run_podman pod rm $podname

    # Pod no longer exists
    run_podman 1 pod exists $podid
    run_podman 1 pod exists $podname
}

@test "podman pod - communicating via /dev/shm " {
    podname=pod$(random_string)
    run_podman 1 pod exists $podname
    run_podman pod create --infra=true --name=$podname
    podid="$output"
    run_podman pod exists $podname
    run_podman pod exists $podid

    run_podman run --rm --pod $podname $IMAGE touch /dev/shm/test1
    run_podman run --rm --pod $podname $IMAGE ls /dev/shm/test1
    is "$output" "/dev/shm/test1"

    # ...then rm the pod, then rmi the pause image so we don't leave strays.
    run_podman pod rm $podname

    # Pod no longer exists
    run_podman 1 pod exists $podid
    run_podman 1 pod exists $podname

    # Pause image hasn't been pulled
    run_podman 1 image exists k8s.gcr.io/pause:3.5
}

# Random byte
function octet() {
    echo $(( $RANDOM & 255 ))
}

# random MAC address: convention seems to be that 2nd lsb=1, lsb=0
# (i.e. 0bxxxxxx10) in the first octet guarantees a private space.
# FIXME: I can't find a definitive reference for this though
# Generate the address IN CAPS (A-F), but we will test it in lowercase.
function random_mac() {
    local mac=$(printf "%02X" $(( $(octet) & 242 | 2 )) )
    for i in $(seq 2 6); do
        mac+=$(printf ":%02X" $(octet))
    done

    echo $mac
}

# Random RFC1918 IP address
function random_ip() {
    local ip="172.20"
    for i in 1 2;do
        ip+=$(printf ".%d" $(octet))
    done
    echo $ip
}

@test "podman pod create - hashtag AllTheOptions" {
    mac=$(random_mac)
    add_host_ip=$(random_ip)
    add_host_n=$(random_string | tr A-Z a-z).$(random_string | tr A-Z a-z).xyz

    dns_server=$(random_ip)
    dns_opt="ndots:$(octet)"
    dns_search=$(random_string 15 | tr A-Z a-z).abc

    hostname=$(random_string | tr A-Z a-z).$(random_string | tr A-Z a-z).net

    labelname=$(random_string 11)
    labelvalue=$(random_string 22)

    pod_id_file=${PODMAN_TMPDIR}/pod-id-file

    # Randomly-assigned ports in the 5xxx and 6xxx range
    port_in=$(random_free_port 5000-5999)
    port_out=$(random_free_port 6000-6999)

    # Create a pod with all the desired options
    # FIXME: --ip=$ip fails:
    #      Error adding network: failed to allocate all requested IPs
    local mac_option="--mac-address=$mac"

    # Create a custom image so we can test --infra-image and -command.
    # It will have a randomly generated infra command, using the
    # existing 'pause' script in our testimage. We assign a bogus
    # entrypoint to confirm that --infra-command will override.
    local infra_image="infra_$(random_string 10 | tr A-Z a-z)"
    local infra_command="/pause_$(random_string 10)"
    local infra_name="infra_container_$(random_string 10 | tr A-Z a-z)"
    run_podman build -t $infra_image - << EOF
FROM $IMAGE
RUN ln /home/podman/pause $infra_command
ENTRYPOINT ["/original-entrypoint-should-be-overridden"]
EOF

    if is_rootless; then
        mac_option=
    fi
    run_podman pod create --name=mypod                   \
               --pod-id-file=$pod_id_file                \
               $mac_option                               \
               --hostname=$hostname                      \
               --add-host   "$add_host_n:$add_host_ip"   \
               --dns        "$dns_server"                \
               --dns-search "$dns_search"                \
               --dns-opt    "$dns_opt"                   \
               --publish    "$port_out:$port_in"         \
               --label      "${labelname}=${labelvalue}" \
               --infra-image   "$infra_image"            \
               --infra-command "$infra_command"          \
               --infra-name "$infra_name"
    pod_id="$output"

    # Check --pod-id-file
    is "$(<$pod_id_file)" "$pod_id" "contents of pod-id-file"

    # Get ID of infra container
    run_podman pod inspect --format '{{(index .Containers 0).ID}}' mypod
    local infra_cid="$output"
    # confirm that entrypoint is what we set
    run_podman container inspect --format '{{.Config.Entrypoint}}' $infra_cid
    is "$output" "$infra_command" "infra-command took effect"
    # confirm that infra container name is set
    run_podman container inspect --format '{{.Name}}' $infra_cid
    is "$output" "$infra_name" "infra-name took effect"

    # Check each of the options
    if [ -n "$mac_option" ]; then
        run_podman run --rm --pod mypod $IMAGE ip link show
        # 'ip' outputs hex in lower-case, ${expr,,} converts UC to lc
        is "$output" ".* link/ether ${mac,,} " "requested MAC address was set"
    fi

    run_podman run --rm --pod mypod $IMAGE hostname
    is "$output" "$hostname" "--hostname set the hostname"
    run_podman 125 run --rm --pod mypod --hostname foobar $IMAGE hostname
    is "$output" ".*invalid config provided: cannot set hostname when joining the pod UTS namespace: invalid configuration" "--hostname should not be allowed in share UTS pod"

    run_podman run --rm --pod $pod_id $IMAGE cat /etc/hosts
    is "$output" ".*$add_host_ip $add_host_n" "--add-host was added"
    is "$output" ".*	$hostname"            "--hostname is in /etc/hosts"
    #               ^^^^ this must be a tab, not a space

    run_podman run --rm --pod mypod $IMAGE cat /etc/resolv.conf
    is "$output" ".*nameserver $dns_server"  "--dns [server] was added"
    is "$output" ".*search $dns_search"      "--dns-search was added"
    is "$output" ".*options $dns_opt"        "--dns-opt was added"

    # pod inspect
    run_podman pod inspect --format '{{.Name}}: {{.ID}} : {{.NumContainers}} : {{.Labels}}' mypod
    is "$output" "mypod: $pod_id : 1 : map\[${labelname}:${labelvalue}]" \
       "pod inspect --format ..."

    # pod ps
    run_podman pod ps --format '{{.ID}} {{.Name}} {{.Status}} {{.Labels}}'
    is "$output" "${pod_id:0:12} mypod Running map\[${labelname}:${labelvalue}]"  "pod ps"

    run_podman pod ps --no-trunc --filter "label=${labelname}=${labelvalue}" --format '{{.ID}}'
    is "$output" "$pod_id" "pod ps --filter label=..."

    # Test local port forwarding, as well as 'ps' output showing ports
    # Run 'nc' in a container, waiting for input on the published port.
    c_name=$(random_string 15)
    run_podman run -d --pod mypod --name $c_name $IMAGE nc -l -p $port_in
    cid="$output"

    # Try running another container also listening on the same port.
    run_podman 1 run --pod mypod --name dsfsdfsdf $IMAGE nc -l -p $port_in
    is "$output" "nc: bind: Address in use" \
       "two containers cannot bind to same port"

    # make sure we can ping; failure here might mean that capabilities are wrong
    run_podman run --rm --pod mypod $IMAGE ping -c1 127.0.0.1
    run_podman run --rm --pod mypod $IMAGE ping -c1 $hostname

    # While the container is still running, run 'podman ps' (no --format)
    # and confirm that the output includes the published port
    run_podman ps --filter id=$cid
    is "${lines[1]}" "${cid:0:12}  $IMAGE  nc -l -p $port_in .* 0.0.0.0:$port_out->$port_in/tcp  $c_name" \
       "output of 'podman ps'"

    # send a random string to the container. This will cause the container
    # to output the string to its logs, then exit.
    teststring=$(random_string 30)
    echo "$teststring" | nc 127.0.0.1 $port_out

    # Confirm that the container log output is the string we sent it.
    run_podman logs $cid
    is "$output" "$teststring" "test string received on container"

    # Finally, confirm the infra-container and -command. We run this late,
    # not at pod creation, to give the infra container time to start & log.
    run_podman logs $infra_cid
    is "$output" "Confirmed: testimage pause invoked as $infra_command" \
       "pod ran with our desired infra container + command"

    # Clean up
    run_podman rm $cid
    run_podman pod rm -t 0 -f mypod
    run_podman rmi $infra_image
}

@test "podman pod create should fail when infra-name is already in use" {
    local infra_name="infra_container_$(random_string 10 | tr A-Z a-z)"
    local pod_name="$(random_string 10 | tr A-Z a-z)"

    # Note that the internal pause image is built even when --infra-image is
    # set to the K8s one.
    run_podman pod create --name $pod_name --infra-name "$infra_name" --infra-image "k8s.gcr.io/pause:3.5"
    run_podman '?' pod create --infra-name "$infra_name"
    if [ $status -eq 0 ]; then
        die "Podman should fail when user try to create two pods with the same infra-name value"
    fi
    run_podman pod rm -f $pod_name
    run_podman images -a

    # Pause image hasn't been pulled
    run_podman 1 image exists k8s.gcr.io/pause:3.5
}

@test "podman pod create --share" {
    local pod_name="$(random_string 10 | tr A-Z a-z)"
    run_podman 125 pod create --share bogus --name $pod_name
    is "$output" ".*Invalid kernel namespace to share: bogus. Options are: cgroup, ipc, net, pid, uts or none" \
       "pod test for bogus --share option"
    run_podman pod create --share cgroup,ipc --name $pod_name
    run_podman run --rm --pod $pod_name --hostname foobar $IMAGE hostname
    is "$output" "foobar" "--hostname should work with non share UTS namespace"
}

@test "podman pod create --pod new:$POD --hostname" {
    local pod_name="$(random_string 10 | tr A-Z a-z)"
    run_podman run --rm --pod "new:$pod_name" --hostname foobar $IMAGE hostname
    is "$output" "foobar" "--hostname should work when creating a new:pod"
    run_podman pod rm $pod_name
    run_podman run --rm --pod "new:$pod_name" $IMAGE hostname
    is "$output" "$pod_name" "new:POD should have hostname name set to podname"
}
# vim: filetype=sh
