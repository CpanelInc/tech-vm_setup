#!/usr/local/cpanel/3rdparty/bin/perl

use diagnostics;
use warnings;
use strict;

use Test::NoWarnings;
use Test::More tests => 9;

use VMS;

# calls that VMS currently makes as of 8/12
# system_formatted( "/usr/local/cpanel/bin/uapi --user=cptest Email add_pop email=testing\@cptest.tld password=" . $rndpass );
# system_formatted("/usr/local/cpanel/bin/uapi --user=cptest Mysql create_database name=cptest_testdb");
# system_formatted( "/usr/local/cpanel/bin/uapi --user=cptest Mysql create_user name=cptest_testuser password=" . $rndpass );
# system_formatted("/usr/local/cpanel/bin/uapi --user=cptest Mysql set_privileges_on_database user=cptest_testuser database=cptest_testdb privileges='ALL PRIVILEGES'");

require_ok('VMS');

is( VMS::_process_uapi_output(),                        0, 'test with no arguments passed' );
is( VMS::_process_uapi_output('bogus argument passed'), 0, 'test with one bogus argument' );
is( VMS::_process_uapi_output( 'bogus', 'arguments', 'passed' ), 0, 'test with multiple bogus arguments' );

my @output = (
    "--- ",
    "apiversion: 3",
    "func: list_backups",
    "module: Backup",
    "result: ",
    "  data: []",
    "",
    "  errors: ~",
    "  messages: ~",
    "  metadata: ",
    "    cnt: 0",
    "    transformed: 1",
    "  status: 1",
    "  warnings: ~"
);
is( VMS::_process_uapi_output(@output), 0, 'valid data but using a uapi call that VMS does not currently make' );

@output = (
    "--- ",
    "apiversion: 3",
    "func: get_instance_settings",
    "module: cPAddons",
    "result: ",
    "  data: ~",
    "  errors: ",
    "    - The system could not locate the “” instance.",
    "  messages: ~",
    "  metadata: {}",
    "",
    "  status: 0",
    "  warnings: ~"
);
like( VMS::_process_uapi_output(@output), qr/The system could not locate/, 'uapi call fails on a call that VMS does not make' );

@output = (
    "--- ",
    "apiversion: 3",
    "func: add_pop",
    "module: Email",
    "result: ",
    "  data: ~",
    "  errors: ",
    q[    - The account testing@cptest.tld already exists!],
    "  messages: ~",
    "  metadata: {}",
    "",
    "  status: 0",
    "  warnings: ~"
);
like( VMS::_process_uapi_output(@output), qr/The account .*already exists/, 'uapi call fails' );

@output = (
    q[--- ],
    q[apiversion: 3],
    q[func: add_pop],
    q[module: Email],
    q[result: ],
    q[  data: testing+cptest2.tld],
    q[  errors: ~],
    q[  messages: ],
    q[    - ''],
    q[  metadata: {}],
    q[],
    q[  status: 1],
    q[  warnings: ~]
);
is( VMS::_process_uapi_output(@output), 0, 'uapi call passes' );
