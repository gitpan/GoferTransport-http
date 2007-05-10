package DBI::Gofer::Transport::mod_perl;

use strict;
use warnings;

our $VERSION = sprintf("0.%06d", q$Revision: 9533 $ =~ /(\d+)/o);

use Sys::Hostname qw(hostname);
use List::Util qw(min max sum);

use DBI qw(dbi_time);
use DBI::Gofer::Execute;

use constant MP2 => ( exists $ENV{MOD_PERL_API_VERSION} and $ENV{MOD_PERL_API_VERSION} >= 2 );
BEGIN {
  if (MP2) {
      warn "USE WITH mod_perl2 NOT RECENTLY TESTED"; # probably broke, probably easy to fix
    require Apache2::RequestIO;
    require Apache2::RequestRec;
    require Apache2::RequestUtil;
    require Apache2::Const;
    Apache2::Const->import(-compile => qw(OK SERVER_ERROR));
  } else {
    require Apache::Constants;
    Apache::Constants->import(qw(OK SERVER_ERROR));
  }
}
use Apache::Util qw(escape_html);

use base qw(DBI::Gofer::Transport::Base);

my $transport = __PACKAGE__->new();

my %executor_configs = ( default => { } );
my %executor_cache;

_install_apache_status_menu_items(
    DBI_gofer => [ 'DBI Gofer', \&_apache_status_dbi_gofer ],
);


sub handler : method {
    my $self = shift;
    my $r = shift;

    eval {
        my $time_received = dbi_time();
        my $executor = $self->executor_for_apache_request($r);

        $r->read(my $frozen_request, $r->headers_in->{'Content-length'});
        my $request = $transport->thaw_request($frozen_request);

        my $response = $executor->execute_request( $request );

        my $frozen_response = $transport->freeze_response($response);

        # setup http headers
        # See http://perl.apache.org/docs/general/correct_headers/correct_headers.html

        # provide Content-Length for KeepAlive so it works if people want it
        $r->header_out('Content-Length', length($frozen_response));
        $r->send_http_header('application/x-perl-gofer-response-binary');

        # using a reference here avoids duplicating the (possibly large) frozen response.
        # http://perl.apache.org/docs/1.0/guide/porting.html#Apache__print___and_CORE__print__
        $r->print(\$frozen_response);

        $executor->update_stats($request, $response, $frozen_request, $frozen_response, $time_received);
    };
    if ($@) {
        chomp(my $error = $@);
        warn $error;
        $r->custom_response(SERVER_ERROR, "$error, version $VERSION (DBI $DBI::VERSION) on ".hostname());
        return SERVER_ERROR;
    }

    return OK;
}


sub executor_for_apache_request {
    my ($self, $r) = @_;
    my $uri = $r->uri;

    return $executor_cache{ $uri } ||= do {

        my $r_dir_config = $r->dir_config;
        # get all configs for this location in sequence ('closest' last)
        my @location_configs = $r_dir_config->get('GoferConfig');

        my $merged_config = $self->_merge_named_configurations( $uri, \@location_configs, 1 );
        DBI::Gofer::Execute->new($merged_config);
    }
}


sub _merge_named_configurations {
    my ($self, $tag, $location_configs_ref, $verbose) = @_;
    my @location_configs = @$location_configs_ref;

    push @location_configs, 'default' unless @location_configs;

    my $proto_config = DBI::Gofer::Execute->valid_configuration_attributes();

    # merge all configs for this location in sequence, later override earlier
    my %merged_config;
    for my $config_name ( @location_configs ) {
        my $config = $executor_configs{$config_name};
        if (!$config) {
            # die if an unknown config is requested but not defined
            # (don't die for 'default' unless it was explicitly requested)
            die "$tag: GoferConfig '$config_name' not defined";
        }
        while ( my ($item_name, $proto_type) = each %$proto_config ) {
            next if not exists $config->{$item_name};
            my $item_value = $config->{$item_name};
            if (ref $proto_type eq 'HASH') {
                my $merged = $merged_config{$item_name} ||= {};
                warn "$tag: GoferConfig $config_name $item_name (@{[ %$item_value ]})\n"
                    if $verbose && keys %$item_value;
                $merged->{$_} = $item_value->{$_} for keys %$item_value;
            }
            else {
                warn "$tag: GoferConfig $config_name $item_name: '$item_value'\n"
                    if $verbose && defined $item_value;
                $merged_config{$item_name} = $item_value;
            }
        }
    }
    return \%merged_config;
}


sub add_configurations {           # one-time setup from httpd.conf
    my ($self, $configs) = @_;
    my $proto_config = DBI::Gofer::Execute->valid_configuration_attributes();
    while ( my ($config_name, $config) = each %$configs ) {
        my @bad = grep { not exists $proto_config->{$_} } keys %$config;
        die "Invalid keys in $self configuration '$config_name': @bad\n"
            if @bad;
        # XXX should check the types here?
    }
    # update executor_configs with new ones
    $executor_configs{$_} = $configs->{$_} for keys %$configs;
}


# --------------------------------------------------------------------------------

sub _install_apache_status_menu_items {
    my %apache_status_menu_items = @_;
    my $apache_status_class;
    if (MP2) {
        $apache_status_class = "Apache2::Status" if Apache2::Module::loaded('Apache2::Status');
    }
    elsif ($INC{'Apache.pm'}                       # is Apache.pm loaded?
        and Apache->can('module')               # really?
        and Apache->module('Apache::Status')) { # Apache::Status too?
        $apache_status_class = "Apache::Status";
    }
    if ($apache_status_class) {
        while ( my ($url, $menu_item) = each %apache_status_menu_items ) {
            $apache_status_class->menu_item($url => @$menu_item);
        }
    }
}


sub _apache_status_dbi_gofer {
    my ($r, $q) = @_;
    my $url = $r->uri;
    my $args = $r->args;
    require Data::Dumper;
    local $Data::Dumper::Indent    = 1;
    local $Data::Dumper::Terse     = 1;
    local $Data::Dumper::Useqq     = 1;
    local $Data::Dumper::Sortkeys  = 1;
    local $Data::Dumper::Quotekeys = 0;
    local $Data::Dumper::Deparse   = 0;
    local $Data::Dumper::Purity    = 0;

    my @s = ("<pre>",
        "<b>DBI::Gofer::Transport::mod_perl $VERSION</b><p>",
    );
    my $time_now = dbi_time();
    my $path_info = $r->path_info;
    # workaround TransHandler being disabled
    $path_info = $url if not defined $path_info;
    # remove leading perl-status, if present (some versions do this, or else no path_info above)
    $path_info =~ s!^/perl-status!!;
    # hack to enable simple actions to be invoked via the status interface
    my $action = ($path_info =~ s/:(\w+)$//) ? $1 : undef;
    if ($path_info) {
        my $executor = $executor_cache{$path_info}
            or return [ "No Gofer executor found for '$path_info'" ];
        if ($action) {
            if ($action eq 'reset_stats') {
                $executor->{stats} = { _reset_stats_at => localtime(time) };
            }
            else {
                return [ "Unknown action '$action' ignored for $path_info" ];
            }
        }
        my $stats = $executor->{stats} ||= {};
        my $recent_requests = $stats->{recent_requests};
        # don't Data::Dumper all the recent_requests
        local $stats->{recent_requests} = @{$stats->{recent_requests}||[]};
        push @s, escape_html( Data::Dumper::Dumper($executor) );
        push @s, "<hr>";
        my ($idle_total, $dur_total, $time_received_prev, $duration_prev) = (0,0,0,0);
        for my $rr (@$recent_requests) {
            my $time_received = $rr->{time_received};
            my $duration = $rr->{duration};
            my $idle = ($time_received_prev) ? abs($time_received-$time_received_prev)-$duration_prev : 0;
            $rr->{_time_received} ||= localtime($time_received);

            # mark idle periods - handy when testing
            push @s, "<hr>" if $time_received_prev and $idle > 10;

            my $request  = $transport->thaw_request($rr->{request});
            push @s, escape_html( $request->summary_as_text({
                at => $rr->{_time_received},
                age => int($time_now-$time_received),
                idle => $idle,
                size => length($rr->{request}),
            }) );

            my $response = $transport->thaw_response($rr->{response});
            push @s, escape_html( $response->summary_as_text({
                duration => $duration,
                size => length($rr->{response}),
            }) );

            $idle_total += $idle;
            $dur_total  += $duration;
            ($time_received_prev, $duration_prev) = ($time_received, $duration);
        }
        push @s, "<hr>\n";
        if (@$recent_requests) {
            my @rr_requ_size = map { length($_->{request}) }  @$recent_requests;
            push @s, sprintf "Recent request size:  min %d, avg %d, max %d (sum %d for last %d)\n",
                min(@rr_requ_size), sum(@rr_requ_size)/@rr_requ_size, max(@rr_requ_size), sum(@rr_requ_size), scalar @rr_requ_size;

            my @rr_resp_size = map { length($_->{response}) } @$recent_requests;
            push @s, sprintf "Recent response size: min %d, avg %d, max %d (sum %d for last %d)\n",
                min(@rr_resp_size), sum(@rr_resp_size)/@rr_resp_size, max(@rr_resp_size), sum(@rr_resp_size), scalar @rr_resp_size;

            my @rr_resp_dur = map { $_->{duration} } @$recent_requests;
            push @s, sprintf "Recent response time: min %.3fs, avg %.3fs, max %.3fs (sum %d for last %d)\n",
                min(@rr_resp_dur), sum(@rr_resp_dur)/@rr_resp_dur, max(@rr_resp_dur), sum(@rr_resp_dur), scalar @rr_resp_dur;

            push @s, sprintf "Occupancy for those %d requests: %.1f%% (%.3fs busy, %.3fs idle)\n",
                scalar @$recent_requests, $dur_total/($dur_total+$idle_total)*100, $dur_total, $idle_total
        }
        return \@s;
    }

    push @s, "No Gofer executors cached" unless %executor_cache;
    for my $path (sort keys %executor_cache) {
        my $executor = $executor_cache{$path};
        (my $tag = $path) =~ s/\W/_/g;
        push @s, sprintf qq{<a href="#%s"><b>%s</b></a>\n}, $tag, $path;
    }
    push @s, "<hr>\n";
    $url =~ s/\Q$path_info$//; # remove path_info from $url
    for my $path (sort keys %executor_cache) {
        my $executor = $executor_cache{$path};
        (my $tag = $path) =~ s/\W/_/g;
        my $stats = $executor->{stats};
        local $stats->{recent_requests} = @{$stats->{recent_requests}||[]};
        push @s, sprintf qq{<a name="%s" href="%s"><b>%s</b></a> = }, $tag, "$url$path?$args", $path;
        push @s, escape_html( Data::Dumper::Dumper($executor) );
    }
    return \@s;
}

1;

__END__

=head1 NAME
    
DBI::Gofer::Transport::mod_perl - http mod_perl server-side transport for DBD::Gofer

=head1 SYNOPSIS

In httpd.conf:

    <Location /gofer>
        SetHandler perl-script 
        PerlHandler DBI::Gofer::Transport::mod_perl
    </Location>

For a corresponding client-side transport see L<DBD::Gofer::Transport::http>.

=head1 DESCRIPTION

This module implements a DBD::Gofer server-side http transport for mod_perl.
After configuring this into your httpd.conf, users will be able to use the DBI
to connect to databases via your apache httpd.

=head1 CONFIGURATION

Rather than provide a DBI proxy that will connect to any database as any user,
you may well want to restrict access to just one or a few databases.

Or perhaps you want the database passwords to be stored only in httpd.conf so
you don't have to maintain them in all your clients. In this case you'd
probably want to use standard https security and authentication.

These kinds of configurations are supported by DBI::Gofer::Transport::mod_perl.

The most simple configuration looks like:

    <Location /gofer>
        SetHandler perl-script
        PerlHandler DBI::Gofer::Transport::mod_perl
    </Location>

That's equivalent to:

    <Perl>
        DBI::Gofer::Transport::mod_perl->add_configurations({
            default => {
                # ...DBI::Gofer::Transport::mod_perl configuration here...
            },
        });
    </Perl>

    <Location /gofer/example>
        SetHandler perl-script
        PerlSetVar GoferConfig default
        PerlHandler DBI::Gofer::Transport::mod_perl
    </Location>

Refer to L<DBI::Gofer::Transport::mod_perl> documentation for details of the
available configuration items, their behaviour, and their default values.

The DBI::Gofer::Transport::mod_perl->add_configurations({...}) call defines named configurations.
The C<PerlSetVar GoferConfig> clause specifies the configuration to be used for that location.

A single location can specify multiple configurations using C<PerlAddVar>:

        PerlSetVar GoferConfig default
        PerlAddVar GoferConfig example_foo
        PerlAddVar GoferConfig example_bar

in which case the added configurations are merged into the current
configuration for that location.  Conflicting entries in later configurations
override those in earlier ones (for hash references the contents of the hashes
are merged). In this way a small number of configurations can be mix-n-matched
to create specific configurations for specific location urls.

A typical usage might be to define named configurations for each specific
database being used and then define a coresponding location for each of those.
That would also allow standard http location access controls to be used
(though at the moment the http transport doesn't support http authentication).

That approach can also provide a level of indirection by avoiding the need for
the clients to know and use the actual DSN. The clients can just connect to the
specific gofer url with an empty DSN. This means you can change the DSN being used
without having to update the clients.

=head1 Apache::Status

DBI::Gofer::Transport::mod_perl installs an extra "DBI Gofer" menu item into
the Apache::Status menu, so long as the Apache::Status module is loaded first.

This is very useful.

Clicking on the DBI Gofer menu items leads to a page showing the configuration
and statistics for the Gofer executor object associated with each C<Location>
using the DBI::Gofer::Transport::mod_perl handler in the httpd.conf file.

Gofer executor objects are created and cached on first use so when the httpd is
(re)started there won't be any details to show.

Each Gofer executor object shown includes a link that will display more detail
of that particular Gofer executor. Currently the only extra detail shown is a
listing showing recent requests and responses followed by a summary. There's a
lot of useful information here. The number of recent recent requests and
responses shown is controlled by the C<track_recent> configuration value.


=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to
C<bug-dbi-gofer-transport-mod_perl@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.

=head1 METHODS

=head2 add_configurations

  DBI::Gofer::Transport::mod_perl->add_configurations( \%hash_of_hashes );

Takes a reference to a hash containing gofer configuration names and their
corresponding configuration details.

These are added to a cache of gofer configurations. Any existing
configurations with the same names are replaced.

A warning will be generated for each configuration that contains any invalid keys.

=head2 executor_for_apache_request

  $executor = $self->executor_for_apache_request( $r );

Takes an Apache request object and returns a DBI::Gofer::Execute object with
the appropriate configuration for the url of the request.

The executors are cached so a new DBI::Gofer::Execute object will be created
only for the first gofer request at a specific url. Subsequent requests get the
cached executor.

=head2 handler

This is the method invoked by Apache mod_perl to handle the request.

=head1 TO DO

Add way to reset the stats via the Apache::Status ui.

Move generic executor config code into DBI::Gofer::Executor::Config or somesuch so other transports can use it.

=head1 AUTHOR

Tim Bunce, L<http://www.linkedin.com/in/timbunce>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007, Tim Bunce, Ireland. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

=head1 SEE ALSO

L<DBD::Gofer> and L<DBD::Gofer::Transport::http>.

=cut
