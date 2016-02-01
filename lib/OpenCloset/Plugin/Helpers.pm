package OpenCloset::Plugin::Helpers;

use Mojo::Base 'Mojolicious::Plugin';

use Parcel::Track;

our $SMS_FROM = '07043257521';

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
    $app->helper( error  => \&error );
    $app->helper( parcel => \&parcel );
    $app->helper( sms    => \&sms );
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

=head2 parcel( $service, $waybill )

    $self->parcel('CJ대한통운', 12345678);
    # https://www.doortodoor.co.kr/parcel/doortodoor.do?fsp_action=PARC_ACT_002&fsp_cmd=retrieveInvNoACT&invc_no=12345678

=cut

sub parcel {
    my ( $self, $service, $waybill ) = @_;

    my $driver;
    {
        no warnings 'experimental';

        given ($service) {
            $driver = 'KR::PostOffice' when /^우체국/;
            $driver = 'KR::CJKorea' when m/^(대한통운|CJ|CJ\s*GLS|편의점)/i;
            $driver = 'KR::KGB' when m/^KGB/i;
            $driver = 'KR::Hanjin' when m/^한진/;
            $driver = 'KR::Yellowcap' when m/^(KG\s*)?옐로우캡/i;
            $driver = 'KR::Dongbu' when m/^(KG\s*)?동부/i;
        }
    }
    return unless $driver;
    return Parcel::Track->new( $driver, $waybill )->uri;
}

=head2 sms( $to, $text, $from? )

    $self->sms('01012345678', 'hi');

=cut

sub sms {
    my ( $self, $to, $text, $from ) = @_;
    return unless $to;
    return unless $text;
    return unless $self->schema;

    return $self->schema->resultset('SMS')->create( { from => $from || $SMS_FROM, to => $to, text => $text } );
}

1;

__END__

=head1 COPYRIGHT

The MIT License (MIT)

Copyright (c) 2016 열린옷장

=cut
