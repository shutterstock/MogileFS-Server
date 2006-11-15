package MogileFS::HTTPFile;
use strict;
use Carp qw(croak);
use Socket qw(PF_INET IPPROTO_TCP SOCK_STREAM);
use MogileFS::Util qw(error);

# (caching the connection used for HEAD requests)
my %head_socket;                # host:port => [$pid, $time, $socket]

my %streamcache;    # host -> IO::Socket::INET to mogstored

# get size of file, return 0 on error.
# tries to finish in 2.5 seconds, under the client's default 3 second timeout.  (configurable)
my %last_stream_connect_error;  # host => $hirestime.

# create a new MogileFS::HTTPFile instance from a URL.  not called
# "new" because I don't want to imply that it's creating anything.
sub at {
    my ($class, $url) = @_;
    my $self = bless {}, $class;

    unless ($url =~ m!^http://([^:/]+)(?::(\d+))?(/.+)$!) {
        croak "Bogus URL.\n";
    }

    $self->{url}  = $url;
    $self->{host} = $1;
    $self->{port} = $2;
    $self->{uri}  = $3;
    return $self;
}

sub device_id {
    my $self = shift;
    return $self->{devid} if $self->{devid};
    $self->{url} =~ /\bdev(\d+)\b/
        or die "Can't find device from URL: $self->{url}\n";
    return $self->{devid} = $1;
}

sub host_id {
    my $self = shift;

    # TODO: kinda gross, replace with MogileFS::Host and MogileFS::Device
    # objects...
    my $devsum = Mgd::get_device_summary();
    my $devid  = $self->device_id;
    return 0 unless $devsum->{$devid};
    return $devsum->{$devid}{hostid};
}

# return MogileFS::Device object
sub device {
}

# return MogileFS::Host object
sub host {
}

# returns 0 on error, advertising error
sub size {
    my $self = shift;
    my ($host, $port, $uri, $path) = map { $self->{$_} } qw(host port uri url);

    # don't sigpipe us
    my $flag_nosignal = MogileFS::Sys->flag_nosignal;
    local $SIG{'PIPE'} = "IGNORE" unless $flag_nosignal;

    # setup for sending size request to cached host
    my $req = "size $uri\r\n";
    my $reqlen = length $req;
    my $rv = 0;
    my $sock = $streamcache{$host};

    my $start_time = Time::HiRes::time();

    my $httpsock;
    my $start_connecting_to_http = sub {
        return if $httpsock;  # don't allow starting connecting twice

        # try to reuse cached socket
        if (my $cached = $head_socket{"$host:$port"}) {
            my ($pid, $conntime, $cachesock) = @{ $cached };
            # see if it's still connected
            if ($pid == $$ && getpeername($cachesock) &&
                $conntime > $start_time - 15 &&
                # readability would indicated conn closed, or garbage:
                ! Mgd::wait_for_readability(fileno($cachesock), 0.00))
            {
                $httpsock = $cachesock;
                return;
            }
        }

        socket $httpsock, PF_INET, SOCK_STREAM, IPPROTO_TCP;
        IO::Handle::blocking($httpsock, 0);
        connect $httpsock, Socket::sockaddr_in($port, Socket::inet_aton($host));
    };

    # sub to parse the response from $sock.  returns undef on error,
    # or otherwise the size of the $path in bytes.
    my $node_timeout = MogileFS->config("node_timeout");
    my $stream_response_timeout = 1.0;
    my $read_timed_out = 0;

    my $parse_response = sub {
        # give the socket 1 second to become readable until we get
        # scared of no reply and start connecting to HTTP to do a HEAD
        # request.  if both timeout, we know the machine is gone, but
        # we don't want to wait 2 seconds + 2 seconds... prefer to do
        # connects in parallel to reduce overall latency.
        unless (Mgd::wait_for_readability(fileno($sock), $stream_response_timeout)) {
            $start_connecting_to_http->();
            # give the socket its final time to get to 2 seconds
            # before we really give up on it
            unless (Mgd::wait_for_readability(fileno($sock), $node_timeout - $stream_response_timeout)) {
                $read_timed_out = 1;
                close($sock);
                return undef;
            }
        }

        # now we know there's readable data
        my $line = <$sock>;
        return undef unless defined $line;
        return undef unless $line =~ /^(\S+)\s+(-?\d+)/; # expected format: "uri size"
        return error("get_file_size() requested size of $path, got back size of $1 ($2 bytes)")
            if $1 ne $uri;
        return 0 if $2 < 0;   # backchannel sends back -1 on errors, which we need to map to 0
        return $2+0;
    };

    my $conn_timeout = 2;

    # try using the cached socket
    if ($sock) {
        $rv = send($sock, $req, $flag_nosignal);
        if ($!) {
            undef $streamcache{$host};
        } elsif ($rv != $reqlen) {
            return error("send() didn't return expected length ($rv, not $reqlen) for $path");
        } else {
            # success
            my $size = $parse_response->();
            return $size if defined $size;
            undef $streamcache{$host};
        }
    }
    # try creating a connection to the stream
    elsif (($last_stream_connect_error{$host} ||= 0) < $start_time - 15.0)
    {
        $sock = IO::Socket::INET->new(PeerAddr => $host,
                                      PeerPort => MogileFS->config("mogstored_stream_port"),
                                      Timeout  => $conn_timeout);

        $streamcache{$host} = $sock;
        if ($sock) {
            $rv = send($sock, $req, $flag_nosignal);
            if ($!) {
                return error("error talking to mogstored stream ($path): $!");
            } elsif ($rv != $reqlen) {
                return error("send() didn't return expected length ($rv, not $reqlen) for $path");
            } else {
                # success
                my $size = $parse_response->();
                return $size if defined $size;
                undef $streamcache{$host};
            }
        } else {
            # see if we timed out connecting.
            my $elapsed = Time::HiRes::time() - $start_time;
            if ($elapsed > $conn_timeout - 0.2) {
                return error("node $host seems to be down in get_file_size");
            } else {
                # cache that we can't connect to the mogstored stream
                # port for people using only apache/lighttpd (dav) on
                # the storage nodes
                $last_stream_connect_error{$host} = Time::HiRes::time();
            }

        }
    }

    # try HTTP
    $start_connecting_to_http->();  # this will only work once anyway, if we already started above.

    # failure case: use a HEAD request to get the size of the file:
    # give them 2 seconds to connect to server, unless we'd already timed out earlier
    my $time_remain = 2.5 - (Time::HiRes::time() - $start_time);
    return 0 if $time_remain <= 0;

    # did we timeout?
    unless (Mgd::wait_for_writeability(fileno($httpsock), $time_remain)) {
        if (my $worker = MogileFS::ProcManager->is_child) {
            $worker->broadcast_host_unreachable($self->host_id);
        }
        return error("get_file_size() connect timeout for HTTP HEAD for size of $path");
    }

    # did we fail to connect?  (got a RST, etc)
    unless (getpeername($httpsock)) {
        if (my $worker = MogileFS::ProcManager->is_child) {
            $worker->broadcast_device_unreachable($self->device_id);
        }
        return error("get_file_size() connect failure for HTTP HEAD for size of $path");
    }

    my $rv = syswrite($httpsock, "HEAD $uri HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");

    $time_remain = 2.5 - (Time::HiRes::time() - $start_time);
    return 0 if $time_remain <= 0;
    return error("get_file_size() read timeout ($time_remain) for HTTP HEAD for size of $path")
        unless Mgd::wait_for_readability(fileno($httpsock), $time_remain);

    my $first = <$httpsock>;
    return error("get_file_size()'s HEAD request wasn't a 200 OK")
        unless $first && $first =~ m!^HTTP/1\.\d 200!;

    # FIXME: this could block too probably, if we don't get a whole
    # line.  in practice, all headers will come at once, though in same packet/read.
    my $cl = undef;
    my $keep_alive = 0;
    while (defined (my $line = <$httpsock>)) {
        if ($line eq "\r\n") {
            if ($keep_alive) {
                $head_socket{"$host:$port"} = [ $$, Time::HiRes::time(), $httpsock ];
            } else {
                delete $head_socket{"$host:$port"};
            }
            return $cl;
        }
        $cl = $1        if $line =~ /^Content-length: (\d+)/i;
        $keep_alive = 1 if $line =~ /^Connection:.+\bkeep-alive\b/i;
    }
    delete $head_socket{"$host:$port"};

    # no content length found?
    return error("get_file_size() found no content-length header in response for $path");
}


1;