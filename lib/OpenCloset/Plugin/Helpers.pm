package OpenCloset::Plugin::Helpers;

use Mojo::Base 'Mojolicious::Plugin';

=encoding utf8

=head1 NAME

OpenCloset::Plugin::Helpers - opencloset mojo helper

=head1 SYNOPSIS

    # Mojolicious::Lite
    plugin 'OpenCloset::Plugin::Helpers';

    # Mojolicious
    $self->plugin('OpenCloset::Plugin::Helpers');

=cut

sub register {
    my ( $self, $app, $conf ) = @_;

    $app->helper( log => sub { shift->app->log } );
    $app->helper( error => \&error );
}

=head1 HELPERS

=head2 log

shortcut for C<$self-E<gt>app-E<gt>log>

    $self->app->log->debug('message');    # OK
    $self->log->debug('message');         # OK, shortcut

=head2 error( $status, $error )

    get '/foo' => sub {
        my $self = shift;
        my $required = $self->param('something');
        return $self->error(400, 'Failed to validate') unless $required;
    } => 'foo';

=cut

sub error {
    my ( $self, $status, $error ) = @_;

    $self->log->error($error);

    no warnings 'experimental';
    my $template;
    given ($status) {
        $template = 'bad_request' when 400;
        $template = 'not_found' when 404;
        $template = 'exception' when 500;
        default { $template = 'unknown' }
    }

    $self->respond_to(
        json => { status => $status, json => { error => $error || q{} } },
        html => { status => $status, error => $error || q{}, template => $template },
    );

    return;
}

1;

__END__

=head1 COPYRIGHT

The MIT License (MIT)

Copyright (c) 2016 열린옷장

=cut
