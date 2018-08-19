#!/usr/local/cpanel/3rdparty/bin/perl

use diagnostics;
use warnings;
use strict;

use Test::Trap;

use Test::NoWarnings;
use Test::More tests => 6;

use VMS;

require_ok('VMS');

subtest 'no arguments' => sub {
    is( VMS::_check_for_failure(), undef, 'correct return value' );
    trap { VMS::_check_for_failure() };
    is( $trap->die, undef, 'did not die' );
};

subtest 'multiple arguments' => sub {
    is( VMS::_check_for_failure( 'this', 'should', 'not', 'matter' ), undef, 'correct return value' );
    trap { VMS::_check_for_failure( 'this', 'should', 'not', 'matter' ) };
    is( $trap->die, undef, 'did not die' );
};

subtest 'license check passed' => sub {
    is( VMS::_check_for_failure('Updating cPanel license...Done. Update succeeded.'), undef, 'correct return value' );
    trap { VMS::_check_for_failure('Updating cPanel license...Done. Update succeeded.') };
    is( $trap->die, undef, 'did not die' );
};

subtest 'license check failed' => sub {
    trap { VMS::_check_for_failure('This does not really matter....Update Failed!') };
    like( $trap->die, '/cPanel license is not currently valid/', 'VMS died here due to invalid license' );
};
