package OpenCloset::Plugin::Helpers;

use Mojo::Base 'Mojolicious::Plugin';

use Config::INI::Reader;
use Date::Holidays::KR ();
use DateTime;
use Digest::MD5 qw/md5_hex/;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP qw();
use Mojo::ByteStream;
use Mojo::DOM::HTML;
use Mojo::URL;
use Parcel::Track;
use Try::Tiny;

use OpenCloset::Constants::Status qw/$RENTAL $RENTABLE/;

our $SMS_FROM = '0269291029';

our $INTERVAL = 55;
our %CHAR2DECIMAL;
map { $CHAR2DECIMAL{$_} = '0' . $_ } ( 0 .. 9 );
map { $CHAR2DECIMAL{$_} = hex($_) } ( 'A' .. 'F' );
map { $CHAR2DECIMAL{$_} = ord($_) - $INTERVAL } ( 'G' .. 'Z' );

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
    $app->helper( error         => \&error );
    $app->helper( parcel        => \&parcel );
    $app->helper( sms           => \&sms );
    $app->helper( holidays      => \&holidays );
    $app->helper( footer        => \&footer );
    $app->helper( send_mail     => \&send_mail );
    $app->helper( code2decimal  => \&code2decimal );
    $app->helper( oavatar_url   => \&oavatar_url );
    $app->helper( clothes2link  => \&clothes2link );
    $app->helper( age           => \&age );
    $app->helper( recent_orders => \&recent_orders );
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

requires C<$ENV{OPENCLOSET_EXTRA_HOLIDAYS}> ini file path

=over

=item $year - 4 digit string

    my $hashref = $self->holidays(2016);    # KR holidays in 2016

=back

=cut

sub holidays {
    my ( $self, $year ) = @_;
    return unless $year;

    my @holidays;
    my $holidays = Date::Holidays::KR::holidays($year);
    for my $mmdd ( keys %{ $holidays || {} } ) {
        my $mm = substr $mmdd, 0, 2;
        my $dd = substr $mmdd, 2;
        push @holidays, "$year-$mm-$dd";
    }

    if ( my $ini = $ENV{OPENCLOSET_EXTRA_HOLIDAYS} ) {
        my $extra_holidays = Config::INI::Reader->read_file($ini);
        for my $mmdd ( keys %{ $extra_holidays->{$year} || {} } ) {
            my $mm = substr $mmdd, 0, 2;
            my $dd = substr $mmdd, 2;
            push @holidays, "$year-$mm-$dd";
        }
    }

    return sort @holidays;
}

=head2 footer

    %= footer;

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
              <br>
              <a href="https://www.theopencloset.net/terms" target="_blank">이용약관</a>
              <a href="https://www.theopencloset.net/privacy" target="_blank">개인정보취급방침</a>
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

=head2 send_mail( $email )

    my $email = Email::Simple->create(header => [..], body => '...');
    $self->send_mail( encode_utf8( $email->as_string ) );

=over

=item $email - RFC 5322 formatted String.

=back

=cut

sub send_mail {
    my ( $self, $email ) = @_;
    return unless $email;

    my $transport = Email::Sender::Transport::SMTP->new( { host => 'localhost' } );
    my $success = try {
        sendmail( $email, { transport => $transport } );
        return 1;
    }
    catch {
        $self->log->error("Failed to sendmail: $_");
        return;
    };

    return $success;
}

=head2 code2decimal

    % code2decimal('J001')
    # 1900-0001

=cut

sub code2decimal {
    my ( $self, $code ) = @_;
    return '' unless $code;

    $code =~ s/^0//;
    my @chars = map { $CHAR2DECIMAL{$_} } split //, $code;
    return sprintf "%02d%02d-%02d%02d", @chars;
}

=head2 oavatar_url

    % oavatar_url(key => $key, %options)
    # https://avatar.theopencloset.net/avatar/900150983cd24fb0d6963f7d28e17f72

C<%options> are optional.

=head3 size

    size => 40    # 40 x 40 image

=head3 default

C<$key> 이미지가 없으면 나타낼 이미지의 주소

    default => "https://secure.wikimedia.org/wikipedia/en/wiki/File:Mad30.jpg"

=cut

sub oavatar_url {
    my ( $self, $key, %options ) = @_;

    my $url = Mojo::URL->new('https://avatar.theopencloset.net');
    unless ($key) {
        $url->path('/avatar/c21f969b5f03d33d43e04f8f136e7682');    # default
        return "$url";
    }

    my $hex = md5_hex($key);
    $url->path("/avatar/$hex");

    if ( my $size = $options{size} ) {
        $url->query( { s => $size } );
    }

    if ( my $default = $options{default} ) {
        $url->query( { d => $default } );
    }

    return "$url";
}

=head2 clothes2link( $clothes, $opts )

    %= clothes2link($clothes)
    # <a href="/clothes/J001">
    #   <span class="label label-primary">
    #     <i class="fa fa-external-link"></i>
    #     J001
    #   </span>
    # </a>

    %= clothes2link($clothes, { with_status => 1, external => 1, class => ['label-success'] })    # external link with status
    # <a href="/clothes/J001" target="_blank">
    #   <span class="label label-primary">
    #     <i class="fa fa-external-link"></i>
    #     J001
    #     <small>대여가능</small>
    #   </span>
    # </a>

=head3 $opt

외부링크로 제공하거나, 상태를 함께 표시할지 여부를 선택합니다.
Default 는 모두 off 입니다.

=over

=item C<1>

상태없이 외부링크로 나타냅니다.

=item C<$hashref>

=over

=item C<$text>

의류코드 대신에 나타낼 text.

=item C<$with_status>

상태도 함께 나타낼지에 대한 Bool.

=item C<$external>

외부링크로 제공할지에 대한 Bool.

=item C<$class>

label 태그에 추가될 css class.

=back

=back

=cut

sub clothes2link {
    my ( $self, $clothes, $opts ) = @_;
    return '' unless $clothes;

    my $code = $clothes->code;
    $code =~ s/^0//;
    my $prefix = '/clothes';
    my $dom    = Mojo::DOM::HTML->new;

    my $html  = "$code";
    my @class = qw/label/;
    if ($opts) {
        if ( ref $opts eq 'HASH' ) {
            if ( my $text = $opts->{text} ) {
                $html = $text;
            }

            if ( $opts->{with_status} ) {
                my $status = $clothes->status;
                my $name   = $status->name;
                my $sid    = $status->id;
                if ( $sid == $RENTABLE ) {
                    push @class, 'label-primary';
                }
                elsif ( $sid == $RENTAL ) {
                    push @class, 'label-danger';
                }
                else {
                    push @class, 'label-default';
                }
                $html .= qq{ <small>$name</small>};
            }
            else {
                push @class, 'label-primary' unless $opts->{class};
            }

            push @class, @{ $opts->{class} ||= [] };

            if ( $opts->{external} ) {
                $html = qq{<i class="fa fa-external-link"></i> } . $html;
                $html = qq{<span class="@class">$html</span>};
                $html = qq{<a href="$prefix/$code" target="_blank">$html</a>};
            }
            else {
                $html = qq{<span class="@class">$html</span>};
                $html = qq{<a href="$prefix/$code">$html</a>};
            }
        }
        else {
            $html = qq{<i class="fa fa-external-link"></i> } . $html;
            $html = qq{<span class="@class">$html</span>};
            $html = qq{<a href="$prefix/$code" target="_blank">$html</a>};
        }
    }
    else {
        $html = qq{<a href="$prefix/$code"><span class="@class">$html</span></a>};
    }

    $dom->parse($html);
    my $tree = $dom->tree;
    return Mojo::ByteStream->new( Mojo::DOM::HTML::_render($tree) );
}

=head2 age

    %= age(2000)
    # 17

=cut

sub age {
    my ( $self, $birth ) = @_;
    my $now = DateTime->now;
    return $now->year - $birth;
}

=head2 recent_orders

Arguments: $order, $limit?
Return: $resultset (scalar context) | @result_objs (list context)

    my $orders = $c->recent_order($order);

사용자의 C<$order> 를 제외한 최근 주문서를 찾습니다.
C<$limit> 의 기본값은 C<5> 입니다.

=cut

sub recent_orders {
    my ( $self, $order, $limit ) = @_;
    return unless $order;

    my $rs
        = $order->user->search_related( 'orders', { -not => { id => $order->id } }, { order_by => { -desc => 'id' } } );

    $limit = 5 unless $limit;
    $rs->slice( 0, $limit - 1 );

    my @orders;
    while ( my $order = $rs->next ) {
        my @details = $order->order_details;
        next unless @details;

        my $jpk;
        for my $detail (@details) {
            my $code = $detail->clothes_code;
            next unless $code;
            next unless $code =~ /^0?[JPK]/;

            $jpk = 1;
            last;
        }

        next unless $jpk;
        push @orders, $order;
    }

    return \@orders;
}

1;

__END__

=head1 COPYRIGHT

The MIT License (MIT)

Copyright (c) 2016 열린옷장

=cut
