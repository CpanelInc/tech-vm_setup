#!/usr/local/cpanel/3rdparty/bin/perl

# vm_setup.pl

use strict;
use warnings;
use Getopt::Long;
use Fcntl;
use IO::Handle;
use IO::Select;
use String::Random;
use IPC::Open3;

my $VERSION = '1.0.1';

# declare variables for script options and hanle them
my ( $help, $verbose, $full, $fast, $force, $cltrue );
GetOptions(
    "help"      => \$help,
    "verbose"   => \$verbose,
    "full"      => \$full,
    "fast"      => \$fast,
    "force"     => \$force,
    "installcl" => \$cltrue,
);

# declare global variables for script
# both of these variables are used during CL install portion
# of script and their necessity should be reviewed during TECH-407
my $InstPHPSelector = 0;
my $InstCageFS      = 0;

# print header
print "\nVM Server Setup Script\n" . "Version: $VERSION\n" . "\n";

# help option should be processed first to ensure that nothing is erroneously executed if this option is passed
# converted this to a function to make main less clunky and it may be of use if we add more script arguments in the future
#  ex:  or die print_help_and_exit();
if ($help) {
    print_help_and_exit();
}

# we should check for the lock file and exit if force argument not passed right after checking for help
# to ensure that no work is performed in this scenario
handle_lock_file();

setup_resolv_conf();

install_packages();
set_screen_perms();

# '/vat/cpanel/cpnat' is sometimes populated with incorrect IP information
# on new openstack builds
# build cpnat too ensure that '/var/cpanel/cpnat' has the correct IPs in it
print "\nbuilding cpnat ";
system_formatted("/usr/local/cpanel/scripts/build_cpnat");

# use a hash for system information
my %sysinfo = (
    "ostype"    => undef,
    "osversion" => undef,
    "tier"      => undef,
    "hostname"  => undef,
    "ip"        => undef,
    "natip"     => undef,
);

# hostname is in the format of 'os.cptier.tld'
get_sysinfo( \%sysinfo );

my $hostname = $sysinfo{'hostname'};
my $natip    = $sysinfo{'natip'};
my $ip       = $sysinfo{'ip'};

# set hostname
print "\nsetting hostname to $hostname";

# use whmapi1 to set hostname so that we get a return value
# this will be important when we start processing output to ensure these calls succeed
# https://documentation.cpanel.net/display/SDK/WHM+API+1+Functions+-+sethostname
system_formatted("/usr/local/cpanel/bin/whmapi1 sethostname hostname=$hostname");

# edit files with the new hostname
configure_99_hostname_cfg($hostname);
configure_sysconfig_network($hostname);
configure_wwwacct_conf( $hostname, $natip );
configure_mainip($natip);
configure_whostmgrft();    # this is really just touching the file in order to skip initial WHM setup
configure_etc_hosts( $hostname, $ip );

add_custom_bashrc_to_bash_profile();

# set env variable
# I am not entirely sure what we need this for or if it is even needed
# leaving for now but will need to be reevaluated in later on
local $ENV{'REMOTE_USER'} = 'root';

# header message for '/etc/motd' placed here to ensure it is added before anything else
add_motd("\n\nVM Setup Script created the following test accounts:\n");

create_api_token();
create_primary_account();

update_tweak_settings();
disable_cphulkd();

# user has option to run upcp and check_cpanel_rpms
# this takes user input if necessary and executes these two processes if desired
handle_additional_options();

# I do not really see a purpose for doing this in this script and on our test vms
# especially since most of the API calls in this script check the license anyway
# and fail if it is not valid
# commenting it out for now and will revisit if it becomes an issue
# one thought if it does prove to be necessary is to change the order so that it gets
# ran before any of the API calls
# update cplicense
# print "\nupdating cpanel license  ";
# system_formatted('/usr/local/cpanel/cpkeyclt');

# install CloudLinux
# this logic should be moved to a subroutine and
# it will be revisited in TECH-407

# looks like this logic should work for now
# from a CL server
# # grep ^rpm_dist /var/cpanel/sysinfo.config
# rpm_dist=cloudlinux
if ( not $force and $sysinfo{'ostype'} eq "cloudlinux" ) {
    print "\nCloudLinux already detected, no need to install CloudLinux.  ";

    # No need to install CloudLinux. It's already installed
    $cltrue = 0;
}
if ($cltrue) {

    # Remove /var/cpanel/nocloudlinux touch file (if it exists)
    if ( -e ("/var/cpanel/nocloudlinux") ) {
        print "\nremoving /var/cpanel/nocloudlinux touch file  ";
        unlink("/var/cpanel/nocloudlinux");
    }
    print "\ndownloading cldeploy shell file  ";
    system_formatted("wget http://repo.cloudlinux.com/cloudlinux/sources/cln/cldeploy");
    print "\nexecuting cldeploy shell file (Note: this runs a upcp and can take time)  ";
    my $clDeploy = qx[ echo | sh cldeploy -k 42-2efe234f2ae327824e879a2bec87fc59 ; echo ];
    print "\ninstalling CageFS  ";
    system_formatted("echo | yum -y install cagefs");
    print "\ninitializing CageFS  ";
    system_formatted("echo | cagefsctl --init");
    print "\ninstalling PHP Selector  ";
    system_formatted("echo | yum -y groupinstall alt-php");
    print "\nupdating CageFS/LVE Manager  ";
    system_formatted("echo | yum -y update cagefs lvemanager");
}

# restart cpsrvd
restart_cpsrvd();

# exit cleanly
clean_exit();

exit;

##############  END OF MAIN ##########################
#
# list of subroutines for the script
#
# system_formatted() - takes a system call as an argument and uses open3() to make the syscall
# add_motd() - appends all argumnets to '/etc/motd'
# get_sysinfo() - populates %sysinfo hash with data
# install_packages() - instals some useful yum packages
# create_api_token() - make API call to creaate an API token with the 'all' acl and add the token to '/etc/motd'
# create_primary_account() - create 'cptest' cPanel acct w/ email address, db, and dbuser - then add info to '/etc/motd'
# update_tweak_settings() - update tweak settings to allow remote domains and unregisteredomains
# disable_cphulkd() - stop and disable cphulkd
# restart_cpsrvd() - restarts cpsrvd
#
# print_help_and_exit() - ran if --help is passed - prints script usage/info and exits
# handle_lock_file() - exit if lock file exists and --force is not passed, otherwise, create lock file
# handle_additional_options() - the script user has option to run a cPanel update and check_cpanel_rpms.  This executes these processes if the user desires
# clean_exit() - print some helpful output for the user before exiting
#
# setup_resolv_conf() - sets '/etc/resolv.conf' to use cPanel resolvers
# configure_99_hostname_cfg() - ensure '/etc/cloud/cloud.cfg.d/99_hostname.cfg' has proper contents
# configure_sysconfig_network() - ensure '/etc/sysconfig/network' has proper contents
# configure_mainip() - ensure '/var/cpanel/mainip' has proper contents
# configure_whostmgrft() - touch '/etc/.whostmgrft' to skip initial WHM setup
# configure_wwwacct_conf() - ensure '/etc/wwwacct.conf' has proper contents
# configure_etc_hosts() - ensure '/etc/hosts' has proper contents
# add_custom_bashrc_to_bash_profile() - append command to '/etc/.bash_profile' that changes source to https://ssp.cpanel.net/aliases/aliases.txt upon login
#
# process_output() - processes the output of syscalls passed to system_formatted()
# print_formatted() - listens to read filehandle from syscall, and prints the output to STDOUT if verbose flag is used
# set_screen_perms() - ensure 'screen' binary has proper ownership/permissions
# ensure_working_rpmdb() - make sure that rpmdb is in working order before making yum syscall
# get_answer() - determines answer from user regarding additional options.  This subroutine takes a prompt string for STDOUT to the user and returns 'y' or 'n' depending on their answer
#
# _gen_pw() - returns a 25 char rand pw
# _stdin() - returns a string taken from STDIN
# _create_touch_file - take file name as argument and works similar to 'touch' command in bash
# _get_ip_and_natip() - called by get_sysinfo() to populate %sysinfo hash with system IP and NATIP
# _get_cpanel_tier - called by get_sysinfo() to populate %sysinfo hash with the cPanel tier
# _get_ostype_and_version() - called by get_sysinfo() to populate %sysinfo hash with the ostype and osversion
# _cpanel_getsysinfo() - called by get_sysinfo() to ensure that '/var/cpanel/sysinfo.config' is up to date
# _cat_file() - takes filename as arg and mimics bash cat command
#
##############  BEGIN SUBROUTINES ####################

# takes a line of output from the syscall as an argument
# and checks for various results
# this will be flushed out further in a later case
# as part of a feature request
sub process_output {

    my $line = shift;

    if ( $line =~ /token:/ ) {
        ( my $key, my $token ) = split /:/, $line;
        add_motd( "Token name - all_access: " . $token . "\n" );
    }

    return 1;
}

# takes a read filehandle from system_formatted() as an argument
# prints text to STDOUT if verbose flag is given
# listens to the file handle for lines of text and sends them to
# process_output() to look for certain restults
sub print_formatted {

    my $r_fh = shift;

    my $sel = IO::Select->new();    # notify us of reads on on our FHs
    $sel->add($r_fh);               # add the FH we are interested in
    while ( my @ready = $sel->can_read ) {
        foreach my $fh (@ready) {
            my $line = <$fh>;
            if ( not defined $line ) {    # EOF for FH
                $sel->remove($fh);
                next;
            }

            else {
                process_output($line);
            }

            if ($verbose) {
                print $line;
            }
        }
    }

    return 1;
}

# takes a system call as an argument and uses open3() to process it
# also call print_formatted() to so that we can process the output of the system call
# and print the results to STDOUT if the verbose flag is used
sub system_formatted {

    my $cmd = shift;
    my ( $pid, $w_fh, $r_fh );

    eval { $pid = open3( $w_fh, $r_fh, '>&STDERR', $cmd ); };
    die "open3: $@\n" if $@;

    if ($verbose) {
        print_formatted($r_fh);
    }

    # wait on child to finish before proceeding
    waitpid( $pid, 0 );

    return 1;
}

# use String::Random to generate 25 digit password
# only use alphanumeric chars in pw
# return the pw
sub _genpw {

    my $gen = String::Random->new();
    return $gen->randregex('\w{25}');
}

# appends argument(s) to the end of /etc/motd
sub add_motd {
    open( my $etc_motd, ">>", '/etc/motd' ) or die $!;
    print $etc_motd "@_\n";
    close $etc_motd;

    return 1;
}

# get stdin from user and return it
sub _stdin {
    my $string = q{};

    chomp( $string = <> );
    return $string;
}

# print script usage information and exit
sub print_help_and_exit {
    print "Usage: perl vm_setup.pl [options]\n\n";
    print "Description: Performs a number of functions to prepare VMs (on service.cpanel.ninja) for immediate use. \n\n";
    print "Options: \n";
    print "-------------- \n";
    print "--force: Ignores previous run check\n";
    print "--fast: Skips all optional setup functions\n";
    print "--verbose: pretty self explanatory\n";
    print "--full: Passes yes to all optional setup functions\n";
    print "--installcl: Installs CloudLinux(can take a while and requires reboot)\n";
    print "Full list of things this does: \n";
    print "-------------- \n";
    print "- Installs common/useful packages\n";
    print "- Sets hostname\n";
    print "- Updates /var/cpanel/cpanel.config (Tweak Settings)\n";
    print "- Performs basic setup wizard\n";
    print "- Fixes /etc/hosts\n";
    print "- Fixes screen permissions\n";

    # print "- Runs cpkeyclt\n";
    print "- Creates test account (with email and database)\n";
    print "- Disables cphulkd\n";
    print "- Creates api key\n";
    print "- Updates motd\n";
    print "- Creates /root/.bash_profile with helpful aliases\n";
    print "- Runs upcp (optional)\n";
    print "- Runs check_cpanel_rpms --fix (optional)\n";
    print "- Downloads and runs cldeploy (Installs CloudLinux) --installcl (optional)\n";
    exit;
}

# script should only be ran once without force
# exit if it has been ran and force not passed
# do nothing if force passed
# create lock file otherwise
sub handle_lock_file {
    if ( -e "/root/vmsetup.lock" ) {
        if ( !$force ) {
            print "/root/vmsetup.lock exists. This script may have already been run. Use --force to bypass. Exiting...\n";
            exit;
        }
        else {
            print "/root/vmsetup.lock exists. --force passed. Ignoring...\n";
        }
    }
    else {
        # create lock file
        print "\ncreating lock file ";
        _create_touch_file('/root/vmsetup.lock');
    }
    return 1;
}

# mimic bash touch command
sub _create_touch_file {
    open( my $touch_file, ">>", "$_[0]" ) or die $!;
    close $touch_file;
    return 1;
}

# recreate resolv.conf using cPanel resolvers
sub setup_resolv_conf {
    print "\nadding resolvers ";
    open( my $etc_resolv_conf, '>', '/etc/resolv.conf' )
      or die $!;
    print $etc_resolv_conf "search cpanel.net\n" . "nameserver 208.74.121.50\n" . "nameserver 208.74.125.59\n";
    close($etc_resolv_conf);
    return 1;
}

###### accepts a reference to a hash
## original declaration
##my %sysinfo = (
##    "ostype"    => undef,
##    "osversion" => undef,
##    "tier"      => undef,
##    "hostname"  => undef,
##    "ip"        => undef,
##    "natip"     => undef,
##    );
sub get_sysinfo {

    # populate '/var/cpanel/sysinfo.config'
    _cpanel_gensysinfo();

    my $ref = shift;

    # get value for keys 'ostype' and 'osversion'
    _get_ostype_and_version($ref);

    # get value for key 'tier'
    _get_cpanel_tier($ref);

    # concatanate it all together
    # get value for key 'hostname'
    $ref->{'hostname'} = $ref->{'ostype'} . $ref->{'osversion'} . '.' . $ref->{'tier'} . ".tld";

    # get value for keys 'ip' and 'natip'
    _get_ip_and_natip($ref);

    return 1;
}

###### accepts a reference to a hash
### original declaration
###my %sysinfo = (
###    "ostype"    => undef,
###    "osversion" => undef,
###    "tier"      => undef,
###    "hostname"  => undef,
###    "ip"        => undef,
###    "natip"     => undef,
###    );
sub _get_ip_and_natip {

    my $ref = shift;
    open( my $fh, '<', '/var/cpanel/cpnat' )
      or die $!;
    while (<$fh>) {
        if ( $_ =~ /^[1-9]/ ) {
            ( $ref->{'natip'}, $ref->{'ip'} ) = split / /, $_;
            chomp( $ref->{'ip'} );
        }
    }
    close $fh;

    return 1;
}

###### accepts a reference to a hash
### original declaration
###my %sysinfo = (
###    "ostype"    => undef,
###    "osversion" => undef,
###    "tier"      => undef,
###    "hostname"  => undef,
###    "ip"        => undef,
###    "natip"     => undef,
###    );
sub _get_cpanel_tier {

    my $ref = shift;
    my $key;
    open( my $fh, '<', '/etc/cpupdate.conf' )
      or die $!;
    while (<$fh>) {
        chomp($_);
        if ( $_ =~ /^CPANEL/ ) {
            ( $key, $ref->{'tier'} ) = split /=/, $_;
        }
    }
    close $fh;

    # replace . with - for hostname purposes
    $ref->{'tier'} =~ s/\./-/g;

    return 1;
}

###### accepts a reference to a hash
### original declaration
###my %sysinfo = (
###    "ostype"    => undef,
###    "osversion" => undef,
###    "tier"      => undef,
###    "hostname"  => undef,
###    "ip"        => undef,
###    "natip"     => undef,
###    );
sub _get_ostype_and_version {

    my $ref = shift;
    my $key;
    open( my $fh, '<', '/var/cpanel/sysinfo.config' )
      or die $!;
    while (<$fh>) {
        chomp($_);
        if ( $_ =~ /^rpm_dist_ver/ ) {
            ( $key, $ref->{'osversion'} ) = split /=/, $_;
        }
        elsif ( $_ =~ /^rpm_dist/ ) {
            ( $key, $ref->{'ostype'} ) = split /=/, $_;
        }
    }
    close $fh;
    return 1;
}

# we need a function to process the output from system_formatted in order to catch and throw exceptions
# in particular, the 'gensysinfo' will throw an exception that needs to be caught if the rpmdb is broken
sub _cpanel_gensysinfo {
    unlink '/var/cpanel/sysinfo.config';
    _create_touch_file('/var/cpanel/sysinfo.config');
    system_formatted("/usr/local/cpanel/scripts/gensysinfo");
    return 1;
}

# verifies the integrity of the rpmdb and install some useful yum packages
sub install_packages {

    # install useful yum packages
    # added perl-CDB_FILE to be installed through yum instead of cpanm
    print "\ninstalling utilities via yum [ mtr nmap telnet nc vim s3cmd bind-utils pwgen jwhois dev git pydf perl-CDB_File ]  ";
    ensure_working_rpmdb();
    system_formatted('/usr/bin/yum -y install mtr nmap telnet nc vim s3cmd bind-utils pwgen jwhois dev git pydf perl-CDB_File');

    return 1;
}

# takes a hostname as an argument
sub configure_99_hostname_cfg {

    my $hn = shift;

    # Now create a file in /etc/cloud/cloud.cfg.d/ called 99_hostname.cfg
    open( my $cloud_cfg, '>', '/etc/cloud/cloud.cfg.d/99_hostname.cfg' )
      or die $!;
    print $cloud_cfg "#cloud-config\n" . "hostname: $hn\n";
    close($cloud_cfg);
    return 1;
}

# takes a hostname as an argument
sub configure_sysconfig_network {

    my $hn = shift;

    # set /etc/sysconfig/network
    print "\nupdating /etc/sysconfig/network  ";
    open( my $etc_network, '>', '/etc/sysconfig/network' )
      or die $!;
    print $etc_network "NETWORKING=yes\n" . "NOZEROCONF=yes\n" . "HOSTNAME=$hn\n";
    close($etc_network);
    return 1;
}

# takes the systems natip as an argument
sub configure_mainip {

    my $nat = shift;

    print "\nupdating /var/cpanel/mainip  ";
    open( my $fh, '>', '/var/cpanel/mainip' )
      or die $!;
    print $fh "$nat";
    close($fh);
    return 1;
}

# touches '/etc/.whostmgrft'
sub configure_whostmgrft {
    _create_touch_file('/etc/.whostmgrft');
    return 1;
}

# takes two arguments
# arg1 = hostname
# arg2 = natip
sub configure_wwwacct_conf {

    my $hn  = shift;
    my $nat = shift;

    # correct wwwacct.conf
    print "\ncorrecting /etc/wwwacct.conf  ";
    open( my $fh, '>', '/etc/wwwacct.conf' )
      or die $!;
    print $fh "HOST $hn\n";
    print $fh "ADDR $nat\n";
    print $fh "HOMEDIR /home\n";
    print $fh "ETHDEV eth0\n";
    print $fh "NS ns1.os.cpanel.vm\n";
    print $fh "NS2 ns2.os.cpanel.vm\n";
    print $fh "NS3\n";
    print $fh "NS4\n";
    print $fh "HOMEMATCH home\n";
    print $fh "NSTTL 86400\n";
    print $fh "TTL 14400\n";
    print $fh "DEFMOD paper_lantern\n";
    print $fh "SCRIPTALIAS y\n";
    print $fh "CONTACTPAGER\n";
    print $fh "CONTACTEMAIL\n";
    print $fh "LOGSTYLE combined\n";
    print $fh "DEFWEBMAILTHEME paper_lantern\n";
    close($fh);
    return 1;
}

# takes two arguments
# # arg1 = hostname
# # arg2 = ip
sub configure_etc_hosts {

    my $hn       = shift;
    my $local_ip = shift;

    # corrent /etc/hosts
    print "\ncorrecting /etc/hosts  ";
    open( my $fh, '>', '/etc/hosts' )
      or die $!;
    print $fh "127.0.0.1    localhost localhost.localdomain localhost4 localhost4.localdomain4\n";
    print $fh "::1          localhost localhost.localdomain localhost6 localhost6.localdomain6\n";
    print $fh "$local_ip    host $hostname\n";
    close($fh);
    return 1;
}

# ensure proper screen ownership/permissions
sub set_screen_perms {

    print "\nfixing screen perms  ";
    system_formatted('/bin/rpm --setugids screen && /bin/rpm --setperms screen');
    return 1;
}

# fixes common issues with rpmdb if they exist
sub ensure_working_rpmdb {
    system_formatted('/usr/local/cpanel/scripts/find_and_fix_rpm_issues');
    return 1;
}

# this creates an api token and adds it to '/etc/motd'
sub create_api_token {

    print "\ncreating api token";
    system_formatted('/usr/local/cpanel/bin/whmapi1 api_token_create token_name=all_access acl-1=all');

    return 1;
}

# create the primary test account
# and add one-liners to motd for access
sub create_primary_account {

    my $rndpass;

    add_motd( "one-liner for access to WHM root access:\n", q(IP=$(awk '{print$2}' /var/cpanel/cpnat); URL=$(whmapi1 create_user_session user=root service=whostmgrd | awk '/url:/ {match($2,"/cpsess.*",URL)}END{print URL[0]}'); echo "https://$IP:2087$URL"), "\n" );

    # create test account
    print "\ncreating test account - cptest  ";
    $rndpass = _genpw();
    system_formatted( "/usr/local/cpanel/bin/whmapi1 createacct username=cptest domain=cptest.tld password=" . $rndpass . " pkgname=my_package savepgk=1 maxpark=unlimited maxaddon=unlimited" );
    add_motd( "one-liner for access to cPanel user: cptest\n", q(IP=$(awk '{print$2}' /var/cpanel/cpnat); URL=$(whmapi1 create_user_session user=cptest service=cpaneld | awk '/url:/ {match($2,"/cpsess.*",URL)}END{print URL[0]}'); echo "https://$IP:2083$URL"), "\n" );

    print "\ncreating test email - testing\@cptest.tld  ";
    $rndpass = _genpw();
    system_formatted( "/usr/local/cpanel/bin/uapi --user=cptest Email add_pop email=testing\@cptest.tld password=" . $rndpass );
    add_motd( "one-liner for access to test email account: testing\@cptest.tld\n", q(IP=$(awk '{print$2}' /var/cpanel/cpnat); URL=$(whmapi1 create_user_session user=testing@cptest.tld service=webmaild | awk '/url:/ {match($2,"/cpsess.*",URL)}END{print URL[0]}'); echo "https://$IP:2096$URL"), "\n" );

    print "\ncreating test database - cptest_testdb  ";
    system_formatted("/usr/local/cpanel/bin/uapi --user=cptest Mysql create_database name=cptest_testdb");

    print "\ncreating test db user - cptest_testuser  ";
    $rndpass = _genpw();
    system_formatted( "/usr/local/cpanel/bin/uapi --user=cptest Mysql create_user name=cptest_testuser password=" . $rndpass );
    add_motd("mysql test user:  username:  cptest_testuser");
    add_motd("                  password:  $rndpass\n");

    print "\nadding all privs for cptest_testuser to cptest_testdb  ";
    system_formatted("/usr/local/cpanel/bin/uapi --user=cptest Mysql set_privileges_on_database user=cptest_testuser database=cptest_testdb privileges='ALL PRIVILEGES'");

    return 1;
}

# update tweak settings to allow creation of nonexistent addon domains
sub update_tweak_settings {

    print "\nUpdating tweak settings (cpanel.config)  ";
    system_formatted("/usr/local/cpanel/bin/whmapi1 set_tweaksetting key=allowremotedomains value=1");
    system_formatted("/usr/local/cpanel/bin/whmapi1 set_tweaksetting key=allowunregistereddomains value=1");
    return 1;
}

# append aliases directly into STDIN upon login
sub add_custom_bashrc_to_bash_profile {

    my $txt = q[ source /dev/stdin <<< "$(curl -s https://ssp.cpanel.net/aliases/aliases.txt)" ];
    open( my $fh, ">>", '/root/.bash_profile' ) or die $!;
    print $fh "$txt\n";
    close $fh;

    return 1;
}

# stop and disable cphulkd
sub disable_cphulkd {

    print "\ndisabling cphulkd  ";
    system_formatted('/usr/local/cpanel/scripts/restartsrv_cphulkd');
    system_formatted('/usr/local/cpanel/bin/cphulk_pam_ctl --disable');

    return 1;
}

# user has option to run upcp and check_cpanel_rpms
# this takes user input if necessary and executes these two processes if desired
sub handle_additional_options {

    # upcp first
    my $answer = get_answer("would you like to run upcp now? [n]: ");
    if ( $answer eq "y" ) {
        print "\nrunning upcp ";
        system_formatted('/scripts/upcp');
    }

    # check_cpanel_rpms second
    $answer = get_answer("\nwould you like to run check_cpanel_rpms now? [n]: ");
    if ( $answer eq "y" ) {
        print "\nrunning check_cpanel_rpms  ";
        system_formatted('/scripts/check_cpanel_rpms --fix');
    }

    return 1;
}

# takes 1 argument - a string to print to obtain user input if necessary
# return y or n
sub get_answer {

    my $question = shift;

    if ($fast) {
        return 'n';
    }
    elsif ($full) {
        return 'y';
    }
    else {
        print $question;
        return _stdin();
    }

    # this should not be possible to reach
    return 1;
}

sub restart_cpsrvd {

    print "\nRestarting cpsvrd  ";
    system_formatted("/usr/local/cpanel/scripts/restartsrv_cpsrvd");
    return 1;
}

# exit cleanly
sub clean_exit {

    print "\nSetup complete\n\n";
    _cat_file('/etc/motd');
    print "\n";
    if ($cltrue) {
        print "\n\nCloudLinux installed! A reboot is required!\n\n";
    }
    else {
        print "\n\nYou should log out and back in.\n\n";
    }

    exit;
}

# takes filename as argument and prints output of file to STDOUT
sub _cat_file {

    my $fn = shift;
    open( my $fh, '<', $fn )
      or die $!;

    while (<$fh>) {
        print $_;
    }

    close $fh;

    return 1;
}
