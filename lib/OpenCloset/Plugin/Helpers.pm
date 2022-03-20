package OpenCloset::Plugin::Helpers;

use Mojo::Base 'Mojolicious::Plugin';

use Algorithm::CouponCode qw(cc_validate);
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

use OpenCloset::Calculator::LateFee ();
use OpenCloset::Constants qw/%MAX_SUIT_TYPE_COUPON_PRICE/;
use OpenCloset::Constants::Status
    qw/$RENTAL $RENTABLE $CHOOSE_CLOTHES $CHOOSE_ADDRESS $PAYMENT $PAYMENT_DONE $WAITING_DEPOSIT $PAYBACK/;
use OpenCloset::Common::Unpaid qw/merchant_uid/;
use OpenCloset::Size::Guess;

our $SMS_FROM     = '0269291020';
our $SHIPPING_FEE = 3_000;
our $DEFAULT_MAX_SUIT_TYPE_COUPON_PRICE = 30_000;

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
    $app->helper( error           => \&error );
    $app->helper( parcel          => \&parcel );
    $app->helper( sms             => \&sms );
    $app->helper( holidays        => \&holidays );
    $app->helper( footer          => \&footer );
    $app->helper( send_mail       => \&send_mail );
    $app->helper( code2decimal    => \&code2decimal );
    $app->helper( oavatar_url     => \&oavatar_url );
    $app->helper( clothes2link    => \&clothes2link );
    $app->helper( age             => \&age );
    $app->helper( recent_orders   => \&recent_orders );
    $app->helper( transfer_order  => \&transfer_order );
    $app->helper( coupon_validate => \&coupon_validate );
    $app->helper( commify         => \&commify );
    $app->helper( merchant_uid    => \&_merchant_uid );
    $app->helper( discount_order  => \&discount_order );
    $app->helper( user_avg_diff   => \&user_avg_diff );
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

    my $schema = $self->app->can('DB') ? $self->app->DB : $self->app->schema;
    return unless $schema;

    return $schema->resultset('SMS')->create( { from => $from || $SMS_FROM, to => $to, text => $text } );
}

=head2 holidays( @years )

requires C<$ENV{OPENCLOSET_EXTRA_HOLIDAYS}> ini file path

=over

=item $year - 4 digit string

    my $hashref = $self->holidays(2016);          # KR holidays in 2016
    my $hashref = $self->holidays(2016, 2017);    # KR holidays in 2016 and 2017

=back

=cut

sub holidays {
    my ( $self, @years ) = @_;
    return unless @years;

    my $extra_holidays = {};
    if ( my $ini = $ENV{OPENCLOSET_EXTRA_HOLIDAYS} ) {
        $extra_holidays = Config::INI::Reader->read_file($ini);
    }

    my @holidays;
    for my $year (@years) {
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
              전화 02-6929-1020
              <br>
              입금계좌 (국민은행) 205737-04-003013 (예금주:사단법인 열린옷장)
              <br>
              <a href="https://www.theopencloset.net/terms" target="_blank">이용약관</a>
              <a href="https://www.theopencloset.net/privacy" target="_blank">개인정보취급방침</a>
              <a href="https://teht.hometax.go.kr/websquare/websquare.html?w2xPath=/ui/ab/a/a/UTEABAAA13.xml" target="_blank">사업자정보확인</a>
            </p>
          </div>
          <div class="col-md-4">
            <h5>링크</h5>
            <ul class="list-inline">
              <li><a href="https://theopencloset.net/">홈페이지</a></li>
              <li><a href="https://visit.theopencloset.net/visit">방문 예약</a></li>
              <li><a href="https://share.theopencloset.net/welcome/">택배주문</a></li>
            </ul>
          </div>
          <div class="col-md-3">
            <h5>Contact</h5>
            <ul class="list-inline">
              <li>
                <a href="https://pf.kakao.com/_xaxcxotE" target="blank">
                  <img src="https://developers.kakao.com/assets/img/about/logos/channel/consult_small_yellow_pc.png" title="카카오톡 채널 1:1 채팅 버튼" alt="카카오톡 채널 1:1 채팅 버튼" srcset="https://developers.kakao.com/assets/img/about/logos/channel/consult_small_yellow_pc_2X.png 2x, https://developers.kakao.com/assets/img/about/logos/channel/consult_small_yellow_pc_3X.png 3x">
                </a>
              </li>
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

=head2 recent_orders( $order_or_$user, $limit? )

    my $orders = $c->recent_order($order);
    my $orders = $c->recent_order($user);

사용자(C<$user>)의 C<$order> 를 제외한 최근 주문서를 찾습니다.
C<$limit> 의 기본값은 C<5> 입니다.

=cut

sub recent_orders {
    my ( $self, $user_or_order, $limit ) = @_;
    return unless $user_or_order;

    my ( $user, $order, $cond );
    my $ref = ref $user_or_order;
    if ( $ref =~ m/User/ ) {
        ## OpenCloset::Schema::Result::User
        $user = $user_or_order;
    }
    elsif ( $ref =~ m/Order/ ) {
        ## OpenCloset::Schema::Result::Order
        $order = $user_or_order;
        $user  = $order->user;
        $cond  = { -not => { id => $order->id } };
    }

    my $rs = $user->search_related( 'orders', $cond, { order_by => { -desc => 'id' } } );

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

=head2 transfer_order($coupon, $order)

B<deprecated>.

    $self->transfer_order( $coupon, $order );

=cut

sub transfer_order {
    my ( $self, $coupon, $to ) = @_;
    return unless $coupon;

    my $code = $coupon->code;
    my $status = $coupon->status || '';

    if ( $status =~ m/(us|discard|expir)ed/ ) {
        $self->log->info("Coupon is not valid: $code($status)");
        return;
    }
    elsif ( $status eq 'reserved' ) {
        my $orders = $coupon->orders;
        unless ( $orders->count ) {
            $self->log->warn("It is reserved coupon, but the order can not be found: $code");
        }

        my @orders;
        while ( my $order = $orders->next ) {
            my $order_id  = $order->id;
            my $coupon_id = $order->coupon_id;
            $self->log->info(
                sprintf( "Delete coupon_id(%d) from existing order(%d): %s", $order->coupon_id, $order->id, $code ) );
            my $return_memo = $order->return_memo;
            $return_memo .= "\n" if $return_memo;
            $return_memo
                .= sprintf(
                "쿠폰의 중복된 요청으로 주문서(%d) 에서 쿠폰(%d)이 삭제되었습니다: %s",
                $order->id, $order->coupon_id, $code );
            $order->update( { coupon_id => undef, return_memo => $return_memo } );

            push @orders, $order->id;
        }

        if ($to) {
            my $return_memo = $to->return_memo;
            if (@orders) {
                $self->log->info(
                    sprintf(
                        "Now, use coupon(%d) in order(%d) %s instead",
                        $coupon->id, $to->id, join( ', ', @orders )
                    )
                );

                $return_memo .= "\n" if $return_memo;
                $return_memo .= sprintf(
                    "%s 에서 사용된 쿠폰(%d)이 주문서(%d)에 사용됩니다: %s",
                    join( ', ', @orders ),
                    $coupon->id, $to->id, $code
                );
            }
            else {
                $self->log->info( sprintf( "Now, use coupon(%d) in order(%d)", $coupon->id, $to->id ) );
            }

            $to->update( { coupon_id => $coupon->id, return_memo => $return_memo } );
        }
    }
    elsif ( $status eq 'provided' || $status eq '' ) {
        $coupon->update( { status => 'reserved' } );
        if ($to) {
            $self->log->info( sprintf( "Now, use coupon(%d) in order(%d)", $coupon->id, $to->id ) );
            $to->update( { coupon_id => $coupon->id } );
        }
    }

    return 1;
}

=head2 coupon_validate

    my ($coupon, $error) = $self->coupon_validate('JY1P-ER09-BEP1');

=cut

sub coupon_validate {
    my ( $self, $code ) = @_;

    my $schema = $self->app->can('DB') ? $self->app->DB : $self->app->schema;
    return unless $schema;

    my $valid_code = cc_validate( code => $code, parts => 3 );
    return ( undef, '유효하지 않은 코드 입니다' ) unless $valid_code;

    my $coupon = $schema->resultset('Coupon')->find( { code => $valid_code } );
    return ( undef, '없는 쿠폰 입니다' ) unless $coupon;

    if ( my $coupon_status = $coupon->status ) {
        return ( undef, "사용할 수 없는 쿠폰입니다: $coupon_status" )
            if $coupon_status =~ m/(us|discard|expir)ed/;
        $self->transfer_order($coupon);
    }

    my $now = DateTime->now;
    if ( my $expires = $coupon->expires_date ) {
        if ( $expires->epoch < $now->epoch ) {
            $self->log->info("coupon is expired: $valid_code");
            $coupon->update( { status => 'expired' } );
            return ( undef, '유효기간이 지난 쿠폰입니다' );
        }
    }

    my $event = $coupon->event;
    if ( $event && $event->end_date ) {
        ## 이벤트 타입과는 상관없다.
        ## 마감일이 예약하는날짜 기준이든 대여일 기준이든 모두 해당됨
        ## 타입을 추가되었을때에 예외처리가 필요하면 분기해야 함
        if ( $event->end_date->epoch < $now->epoch ) {
            my $name = $event->name . ' - ' . $event->title;
            $self->log->info("event($name) is ended: $valid_code");
            return ( undef, sprintf("%s 이벤트가 종료되었습니다. (%s ~ %s)",
                                    $event->title,
                                    $event->start_date->ymd,
                                    $event->end_date->ymd));
        }
    }

    return $coupon;
}

=head2 commify

    commify(1000000);    # 1,000,000

=cut

sub commify {
    my $self = shift;
    local $_ = shift;
    1 while s/((?:\A|[^.0-9])[-+]?\d+)(\d{3})/$1,$2/s;
    return $_;
}

=head2 _merchant_uid

타임스탬프와 임의의 문자를 포함한 거래 식별코드를 생성합니다. iamport 거래
식별코드가 총 40자 제한이 있고, 타임스탬프 등의 문자가 20자이므로 사용자가
지정하는 C<$prefix>는 C<20>자 미만이어야 합니다.

    # merchant-1484777630841-Wfg
    # same as javascript: merchant-' + new Date().getTime() + "-<random_3_chars>"
    my $merchant_uid = $self->merchant_uid;

    # share-3-1484777630841-D8d
    my $merchant_uid = $self->merchant_uid( "share-%d-", $order->id );

=cut

sub _merchant_uid {
    my ( $self, $prefix_fmt, @prefix_params ) = @_;
    return merchant_uid( $prefix_fmt, @prefix_params );
}

=head2 discount_order( $order )

C<$order> 에 C<$order-E<gt>coupon>의 할인금액을 적용합니다.
이미 적용되어있다면 무시합니다.

  +--------+----------+--------------+-----------+---------------+-------+-------------+-------+------+----------+---------------------+
  | id     | order_id | clothes_code | status_id | name          | price | final_price | stage | desc | pay_with | create_date         |
  +--------+----------+--------------+-----------+---------------+-------+-------------+-------+------+----------+---------------------+
  | 318434 |    58025 | 0J003        |        19 | J003 - 재킷   | 10000 |       10000 |     0 | NULL | NULL     | 2017-04-25 18:06:00 |
  | 318435 |    58025 | 0P181        |        19 | P181 - 바지   | 10000 |       10000 |     0 | NULL | NULL     | 2017-04-25 18:06:00 |
  | 318436 |    58025 | NULL         |      NULL | 배송비        |     0 |           0 |     0 | NULL | NULL     | 2017-04-25 18:06:00 |
  | 318437 |    58025 | NULL         |      NULL | 에누리        |     0 |           0 |     0 | NULL | NULL     | 2017-04-25 18:06:00 |
  +--------+----------+--------------+-----------+---------------+-------+-------------+-------+------+----------+---------------------+

  $self->transfer_order($coupon, $order);
  $self->discount_order($order);

  +--------+----------+--------------+-----------+---------------+-------+-------------+-------+------+----------+---------------------+
  | id     | order_id | clothes_code | status_id | name          | price | final_price | stage | desc | pay_with | create_date         |
  +--------+----------+--------------+-----------+---------------+-------+-------------+-------+------+----------+---------------------+
  | 318434 |    58025 | 0J003        |        19 | J003 - 재킷   | 10000 |       10000 |     0 | NULL | NULL     | 2017-04-25 18:06:00 |
  | ...... |    ..... | .....        |        .. | .... . ..    | ..... |       ..... |     . | .... | ....     | .......... ........ |
  | 318438 |    58025 | NULL         |      NULL | 30% 할인쿠폰   | -6000 |       -6000 |     0 | NULL | NULL     | 2017-04-25 18:06:00 |
  +--------+----------+--------------+-----------+---------------+-------+-------------+-------+------+----------+---------------------+

or

  +--------+----------+--------------+-----------+-----------------+--------+-------------+-------+------+----------+---------------------+
  | id     | order_id | clothes_code | status_id | name            | price  | final_price | stage | desc | pay_with | create_date         |
  +--------+----------+--------------+-----------+-----------------+--------+-------------+-------+------+----------+---------------------+
  | 318434 |    58025 | 0J003        |        19 | J003 - 재킷      |  10000 |       10000 |     0 | NULL | NULL     | 2017-04-25 18:06:00 |
  | ...... |    ..... | .....        |        .. | .... . ..       |  ..... |       ..... |     . | .... | ....     | .......... ........ |
  | 318438 |    58025 | NULL         |      NULL | 10,000원 할인쿠폰 | -10000 |     -10000  |     0 | NULL | NULL     | 2017-04-25 18:06:00 |
  +--------+----------+--------------+-----------+-----------------+--------+-------------+-------+------+----------+---------------------+

or

  +--------+----------+--------------+-----------+-----------------+--------+-------------+-------+------+----------+---------------------+
  | id     | order_id | clothes_code | status_id | name            | price  | final_price | stage | desc | pay_with | create_date         |
  +--------+----------+--------------+-----------+-----------------+--------+-------------+-------+------+----------+---------------------+
  | 318434 |    58025 | 0J003        |        19 | J003 - 재킷      |  10000 |       10000 |     0 | NULL | NULL     | 2017-04-25 18:06:00 |
  | ...... |    ..... | .....        |        .. | .... . ..       |  ..... |       ..... |     . | .... | ....     | .......... ........ |
  | 318438 |    58025 | NULL         |      NULL | suit 할인쿠폰     | -20000 |      -20000 |     0 | NULL | NULL     | 2017-04-25 18:06:00 |
  +--------+----------+--------------+-----------+-----------------+--------+-------------+-------+------+----------+---------------------+

=cut

sub discount_order {
    my ( $self, $order ) = @_;
    return unless $order;

    my $coupon = $order->coupon;
    return unless $coupon;

    my $coupon_status = $coupon->status || '';
    return if $coupon_status =~ m/(us|discard|expir)ed/;

    my $rs = $order->order_details( { name => { -like => '%쿠폰%' } }, { rows => 1 } );
    return if $rs->count;

    ## online 에서 쿠폰을 사용했다면 3회 이상 대여 할인을 없앤다.
    my $detail = $order->search_related(
        'order_details',
        { name => '3회 이상 대여 할인', desc => 'additional', },
        { rows => 1 }
    )->single;

    if ($detail) {
        $self->log->info("쿠폰을 사용했기 때문에 3회 이상 대여 할인품목을 제거");
        $detail->delete;
    }

    $self->log->debug("할인 전 주문서정보");
    $self->log->debug("$order");
    for my $detail ($order->order_details) {
        $self->log->debug("$detail");
    }

    ## offline 에서 쿠폰을 사용했다면 할인품목의 가격을 정상가로 되돌린다.
    my $details = $order->search_related( 'order_details', { desc => { -like => '3회 이상%' } } );
    while ( my $detail = $details->next ) {
        my $clothes = $detail->clothes;
        next unless $clothes;

        my $price          = $clothes->price;
        my $additional_day = $order->additional_day;
        $detail->update(
            {
                price       => $price,
                final_price => $price + $price * $OpenCloset::Calculator::LateFee::EXTENSION_RATE * $additional_day,
                desc        => undef,
            }
        );
    }

    my $type = $coupon->type;
    if ( $type eq 'default' ) {
        my $price = $coupon->price;
        $order->create_related(
            'order_details',
            {
                name        => sprintf( "%s원 할인쿠폰", $self->commify($price) ),
                price       => $price * -1,
                final_price => $price * -1,
            }
        );
    }
    elsif ( $type =~ m/(rate|suit)/ ) {
        my $desc = '';
        my $rate = $coupon->price;
        my ( $price, $final_price ) = ( 0, 0 );

        if ( $order->online ) {
            $desc = 'additional';
            my $status_id = $order->status_id;
            if ( "$CHOOSE_CLOTHES $CHOOSE_ADDRESS $PAYMENT $PAYMENT_DONE $WAITING_DEPOSIT $PAYBACK"
                =~ m/\b$status_id\b/ )
            {
                my $details = $order->order_details;
                while ( my $detail = $details->next ) {
                    my $name = $detail->name;
                    next unless $name =~ m/^[a-z]/;

                    $price       += $detail->price;
                    $final_price += $detail->final_price;
                }
            }
            else {
                my $details = $order->order_details( { clothes_code => { '!=' => undef } } );
                while ( my $detail = $details->next ) {
                    $price       += $detail->price;
                    $final_price += $detail->final_price;
                }
            }
        }
        else {
            my $details = $order->order_details( { clothes_code => { '!=' => undef } } );
            while ( my $od = $details->next ) {
                $price       += $od->price;
                $final_price += $od->final_price;
            }
        }

        if ( $type eq 'rate' ) {
            $order->create_related(
                'order_details',
                {
                    name        => sprintf( "%d%% 할인쿠폰", $rate ),
                    price       => ( $price * $rate / 100 ) * -1,
                    final_price => ( $final_price * $rate / 100 ) * -1,
                    desc        => $desc,
                }
            );
        }
        elsif ( $type eq 'suit' ) {
            my $user      = $order->user;
            my $user_info = $user->user_info;
            my $gender    = $user_info->gender;

            ## suit 타입에서는 price 가 coupon 의 최대할인가
            ## 0 으로 발행된 쿠폰이면 기본 할인가를 적용
            my $max_coupon_price = $coupon->price || $MAX_SUIT_TYPE_COUPON_PRICE{$gender} || $DEFAULT_MAX_SUIT_TYPE_COUPON_PRICE;
            if ( $price > $max_coupon_price ) {
                $price = $final_price = $max_coupon_price;
            }

            $order->create_related(
                'order_details',
                {
                    name        => '단벌 할인쿠폰',
                    price       => $price * -1,
                    final_price => $final_price * -1,
                    desc        => $desc
                }
            );
        }
    }

    if ( $order->online ) {
        my $event = $coupon->event;
        my $free_shipping = $coupon->free_shipping || $event ? $event->free_shipping : 0;
        if ($free_shipping) {
            $order->create_related(
                'order_details',
                {
                    name        => "배송비 무료쿠폰",
                    price       => $SHIPPING_FEE * -1,
                    final_price => $SHIPPING_FEE * -1,
                    desc        => 'additional',
                }
            );
        }
    }

    return 1;
}

=head2 user_avg_diff( $user )

=cut

sub user_avg_diff {
    my ( $self, $user ) = @_;

    my %data = ( ret => 0, diff => undef, avg => undef, );
    for (qw/ neck belly topbelly bust arm thigh waist hip leg foot knee /) {
        $data{diff}{$_} = '-';
        $data{avg}{$_}  = 'N/A';
    }

    return \%data unless $user;
    return \%data unless $user->user_info;

    unless ( $user->user_info->gender =~ m/^(male|female)$/
        && $user->user_info->height
        && $user->user_info->weight )
    {
        return \%data;
    }

    my $schema = $self->app->can('DB') ? $self->app->DB : $self->app->schema;
    my $timezone = $self->config->{timezone} || 'Asia/Seoul';

    my $osg_db = OpenCloset::Size::Guess->new(
        'DB', _time_zone => $timezone,
        _schema => $schema, _range => 0,
    );
    $osg_db->gender( $user->user_info->gender );
    $osg_db->height( int $user->user_info->height );
    $osg_db->weight( int $user->user_info->weight );
    my $avg = $osg_db->guess;
    my $diff;
    for (qw/ neck belly topbelly bust arm thigh waist hip leg foot knee /) {
        $diff->{$_} = $user->user_info->$_
            && $avg->{$_} ? sprintf( '%+.1f', $user->user_info->$_ - $avg->{$_} ) : '-';
        $avg->{$_} = $avg->{$_} ? sprintf( '%.1f', $avg->{$_} ) : 'N/A';
    }

    %data = ( ret => 1, diff => $diff, avg => $avg, );

    return \%data;
}

1;

__END__

=head1 COPYRIGHT

The MIT License (MIT)

Copyright (c) 2016 열린옷장

=cut
