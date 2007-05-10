package DBD::Gofer::Transport::http;

#   $Id: http.pm 9533 2007-05-09 15:32:24Z timbo $
#
#   Copyright (c) 2007, Tim Bunce, Ireland
#
#   You may distribute under the terms of either the GNU General Public
#   License or the Artistic License, as specified in the Perl README file.

use strict;
use warnings;

use Carp;
use URI;
use LWP::UserAgent;
use HTTP::Request;

use DBI 1.55;
use base qw(DBD::Gofer::Transport::Base);

our $VERSION = sprintf("0.%06d", q$Revision: 9533 $ =~ /(\d+)/o);

__PACKAGE__->mk_accessors(qw(
    http_req
    http_ua
)); 


sub transmit_request_by_transport {
    my ($self, $request) = @_;

    my $response = eval { 
        my $frozen_request = $self->freeze_request($request);

        my $http_req = $self->{http_req} ||= do {
            my $url = $self->go_url || croak "No url specified";
            my $request = HTTP::Request->new(POST => $url);
            $request->content_type('application/x-perl-gofer-request-binary');
            $request;
        };
        my $http_ua = $self->{http_ua} ||= do {
            my $useragent = LWP::UserAgent->new(
                timeout => $self->go_timeout,   # undef by default
                env_proxy => 1, # XXX
            );
            $useragent->agent(join "/", __PACKAGE__, $DBI::VERSION, $VERSION);
            #$useragent->credentials( $netloc, $realm, $uname, $pass ); XXX
            $useragent->parse_head(0); # don't parse html head
            $useragent;
        };

        my $content = $frozen_request;
        $http_req->header('Content-Length' => length($content)); # in bytes
        $http_req->content($content);

        # Pass request to the user agent and get a response back
        my $res = $http_ua->request($http_req);

        if (not $res->is_success) {
            return DBI::Gofer::Response->new({
                err    => 1, # or 100_000 + $res->status_code? DBI registry codes? XXX
                errstr => $res->status_line,
            }); 
        }

        my $frozen_response = $res->content;

        return $self->thaw_response($frozen_response);
    };
    $response ||= DBI::Gofer::Response->new({ err => 1, errstr => $@||'(no response)' });
    return $response;
}


sub receive_response_by_transport {
    my $self = shift;
    # transmit_request_by_transport does all the work for this driver
    # so receive_response_by_transport should never be called
    croak "receive_response_by_transport should never be called";
}


1;

__END__

=head1 NAME
    
DBD::Gofer::Transport::http - DBD::Gofer client transport using http

=head1 SYNOPSIS

  my $remote_dsn = "..."
  DBI->connect("dbi:Gofer:transport=http;url=http://gofer.example.com/gofer;dsn=$remote_dsn",...)

or, enable by setting the DBI_AUTOPROXY environment variable:

  export DBI_AUTOPROXY='dbi:Gofer:transport=http;url=http://gofer.example.com/gofer'

which will force I<all> DBI connections to be made via that Gofer server.

=head1 DESCRIPTION

Connect with DBI::Gofer servers that use http transports, i.e., L<DBI::Gofer::Transport::mod_perl>.

This module currently uses the L<LWP::UserAgent> and L<HTTP::Request> modules to manage the http protocol.
The default timeout is undef (unlimited). The LWP::UserAgent C<env_proxy> option is enabled.

=head1 ATTRIBUTES

See L<DBD::Gofer::Transport::Base> for a description of the Gofer transport
attributes that are common to all transports, and another common features such
as enabling gofer transport tracing.

The DBD::Gofer::Transport::http transport doesn't add any extra attributes.

=head2 go_timeout

The timeout provided by L<DBD::Gofer::Transport::Base> is used.
The C<go_timeout> value is also passed to LWP::UserAgent as its timeout value.
In practice the DBD::Gofer::Transport::Base timeout would almost certainly fire first.
This area is subject to change in future releases.

=head1 PROTOCOL

The request is sent as a POST with a content type of 'C<application/x-perl-gofer-request-binary>'.

The user-agent string is 'C<DBD::Gofer::Transport::http/><$DBI::VERSION>C</><$VERSION>'.

=head1 METHODS

=head2 transmit_request_by_transport

  $response = $transport->transmit_request_by_transport( $request );

Freezes and transmits the request using the L<LWP::UserAgent> and L<HTTP::Request> modules.
Waits for and returns response. Any exception is caught and returned as a response object.

=head2 receive_response_by_transport

This method isn't used because transmit_request_by_transport() always returns a response object.
If called it throws an exception.

=head1 BUGS AND LIMITATIONS

There is currently no support for http authentication.

Please report any bugs or feature requests to
C<bug-dbi-gofer-transport-mod_perl@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.

=head1 SEE ALSO

L<DBD::Gofer> and L<DBI::Gofer::Transport::mod_perl>

=head1 AUTHOR

Tim Bunce, L<http://www.linkedin.com/in/timbunce>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007, Tim Bunce, Ireland. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

=cut
