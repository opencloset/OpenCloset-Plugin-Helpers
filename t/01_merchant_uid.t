#!/usr/bin/env perl
use Mojo::Base -strict;

use Mojolicious::Lite;
use Test::Mojo;
use Test::More;

plugin 'OpenCloset::Plugin::Helpers';

my $t   = Test::Mojo->new;
my $app = $t->app;

ok( $app->merchant_uid, '$app->merchant_uid : ' . $app->merchant_uid );
like( $app->merchant_uid, qr/^merchant_\d{15,16}-\w{3}$/, 'merchant_uid looks like ^merchant_\d{15,16}-\w{3}$' );

my $order_id = 3542;
like(
    $app->merchant_uid( "share-%d-", $order_id ),
    qr/^share-$order_id-\d{15,16}-\w{3}$/,
    'merchant_uid looks like share-$order_id-\d{15,16}-\w{3}\$'
);

my $prefix = 'veryloooooooooooooongprefix';
is( $app->merchant_uid($prefix),
    undef, '$prefix should be less than 20 char due to overall iamport merchant_uid length limit(40 chr)' );

done_testing;
