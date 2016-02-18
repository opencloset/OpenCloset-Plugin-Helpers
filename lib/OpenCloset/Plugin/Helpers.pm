package OpenCloset::Plugin::Helpers;

use Mojo::Base 'Mojolicious::Plugin';

use Config::INI::Reader;
use Date::Holidays::KR ();
use Mojo::ByteStream;
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
    $app->helper( error    => \&error );
    $app->helper( parcel   => \&parcel );
    $app->helper( sms      => \&sms );
    $app->helper( holidays => \&holidays );
    $app->helper( footer   => \&footer );
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
        $template = 'unauthorized' when 401;
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

    my $schema = $self->app->schema;
    return unless $schema;

    return $schema->resultset('SMS')->create( { from => $from || $SMS_FROM, to => $to, text => $text } );
}

=head2 holidays( $year )

=over

=item $year - 4 digit string

    my $hashref = $self->holidays(2016);    # KR holidays in 2016

=back

=cut

sub holidays {
    my ( $self, $year ) = @_;
    return unless $year;

    my $ini = $self->app->static->file('misc/extra-holidays.ini');
    my $extra_holidays = $ini->path ? Config::INI::Reader->read_file( $ini->path ) : {};

    my @holidays;
    my $holidays = Date::Holidays::KR::holidays($year);
    for my $mmdd ( keys %{ $holidays || {} } ) {
        my $mm = substr $mmdd, 0, 2;
        my $dd = substr $mmdd, 2;
        push @holidays, "$year-$mm-$dd";
    }

    for my $mmdd ( keys %{ $extra_holidays->{$year} || {} } ) {
        my $mm = substr $mmdd, 0, 2;
        my $dd = substr $mmdd, 2;
        push @holidays, "$year-$mm-$dd";
    }

    return sort @holidays;
}

=head2 footer

=cut

sub footer {
    my $self = shift;

    my $html = qq{<footer class="page-footer">
      <div class="container">
        <div class="row">
          <div class="col-md-5">
            <h5>열린옷장</h5>
            <p>
              사단법인 열린옷장 | 이사장 한만일
              <br>
              개인정보관리책임자 김소령
              <br>
              사업자등록번호 498-82-00028
              <br>
              서울특별시 공유단체 제26호
              <br>
              통신판매업신고번호 2016-서울광진-0004
              <br>
              전자우편 info\@theopencloset.net
              <br>
              전화 070-4325-7521
            </p>
          </div>
          <div class="col-md-4">
            <h5>링크</h5>
            <ul class="list-inline">
              <li><a href="https://theopencloset.net/">홈페이지</a></li>
              <li><a href="https://visit.theopencloset.net/">방문 예약</a></li>
              <li><a href="https://online.theopencloset.net/">온라인 예약</a></li>
            </ul>
          </div>
          <div class="col-md-3">
            <h5>Connect</h5>
            <ul class="list-inline">
              <li><a href="https://twitter.com/openclosetnet/"><i class="fa fa-2x fa-twitter-square"></i></a></li>
              <li><a href="https://www.facebook.com/TheOpenCloset/"><i class="fa fa-2x fa-facebook-square"></i></a></li>
              <li><a href="https://www.instagram.com/opencloset_story/"><i class="fa fa-2x fa-instagram"></i></a></li>
              <li><a href="http://theopencloset.tistory.com/"><i class="fa fa-2x fa-rss-square"></i></a></li>
            </ul>
          </div>
        </div>
      </div>
      <div class="footer-copyright">
        <div class="container">
          &copy; 2015 THE OPEN CLOSET. All Rights Reserved.
        </div>
      </div>
  </footer>};

    return Mojo::ByteStream->new($html);
}

1;

__END__

=head1 COPYRIGHT

The MIT License (MIT)

Copyright (c) 2016 열린옷장

=cut
