#!/usr/local/cpanel/3rdparty/bin/perl

use diagnostics;
use warnings;
use strict;

use Test::NoWarnings;
use Test::More tests => 5;

use VMS;

require_ok('VMS');

like( VMS::_genpw('does not take arguments'), '/\w{25}/', 'ignores one argument' );
like( VMS::_genpw( 'does', 'not', 'take', 'arguments' ), '/\w{25}/', 'ignore multiple arguments' );
like( VMS::_genpw(), '/\w{25}/', 'always returns a 25 char alphanumberic string' );
