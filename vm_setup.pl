#!/usr/local/cpanel/3rdparty/bin/perl

# vm_setup.pl

use strict;
use warnings;
use Getopt::Long;
use Fcntl;
use IO::Handle;

local $| = 1;

my $VERSION = '0.6.1';

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
my $ip;
my $token;
our $spincounter;
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
# also converting this to a function to avoid performing tasks in main
handle_lock_file();

# proces full and fast arguments
# full = y
# otherwise, we return n
my $answer = full_or_fast();

setup_resolv_conf();

install_yum_packages();

# '/vat/cpanel/cpnat' is sometimes populated with incorrect IP information
# on new openstack builds
# build cpnat too ensure that '/var/cpanel/cpnat' has the correct IPs in it
print "building cpnat\n";
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

# set hostname
print "\nsetting hostname to $hostname";

# use whmapi1 to set hostname so that we get a return value
# this will be important when we start processing output to ensure these calls succeed
# https://documentation.cpanel.net/display/SDK/WHM+API+1+Functions+-+sethostname
system_formatted("/usr/sbin/whmapi1 sethostname hostname=$hostname");

# edit files with the new hostname
configure_99_hostname_cfg($hostname);
configure_sysconfig_network($hostname);
configure_wwwacct_conf( $hostname, $natip );
configure_mainip($natip);
configure_whostmgrft();    # this is really just touching the file in order to skip initial WHM setup

# correct /etc/hosts
print "\ncorrecting /etc/hosts  ";
unlink '/etc/hosts';
sysopen( my $etc_hosts, '/etc/hosts', O_WRONLY | O_CREAT )
  or die $!;
print $etc_hosts "127.0.0.1		localhost localhost.localdomain localhost4 localhost4.localdomain4\n" . "::1		localhost localhost.localdomain localhost6 localhost6.localdomain6\n" . "$ip		daily $hostname\n";
close($etc_hosts);

# fix screen perms
print "\nfixing screen perms  ";
system_formatted('/bin/rpm --setugids screen && /bin/rpm --setperms screen');

# generate random password
my $rndpass = &random_pass();

add_motd("VM Setup Script created the following test accounts:\n");
add_motd( "one-liner for access to WHM root access:\n", q(IP=$(awk '{print$2}' /var/cpanel/cpnat); URL=$(whmapi1 create_user_session user=root service=whostmgrd | awk '/url:/ {match($2,"/cpsess.*",URL)}END{print URL[0]}'); echo "https://$IP:2087$URL"), "\n" );

# create api token
print "\ncreating api token";
local $ENV{'REMOTE_USER'} = 'root';
system_formatted('/usr/sbin/whmapi1 api_token_create token_name=all_access acl-1=all');
add_motd( "Token name - all_access: " . $token . "\n" );

print "\nInstalling CDB_file.pm Perl Module  ";
system_formatted('/usr/local/cpanel/bin/cpanm --force CDB_File');

# create test account
print "\ncreating test account - cptest  ";
system_formatted( "/usr/sbin/whmapi1 createacct username=cptest domain=cptest.tld password=" . $rndpass . " pkgname=my_package savepgk=1 maxpark=unlimited maxaddon=unlimited" );
add_motd( "one-liner for access to cPanel user: cptest\n", q(IP=$(awk '{print$2}' /var/cpanel/cpnat); URL=$(whmapi1 create_user_session user=cptest service=cpaneld | awk '/url:/ {match($2,"/cpsess.*",URL)}END{print URL[0]}'); echo "https://$IP:2083$URL"), "\n" );

print "\ncreating test email - testing\@cptest.tld  ";
system_formatted( "/usr/bin/uapi --user=cptest Email add_pop email=testing\@cptest.tld password=" . $rndpass );
add_motd( "one-liner for access to test email account: testing\@cptest.tld\n", q(IP=$(awk '{print$2}' /var/cpanel/cpnat); URL=$(whmapi1 create_user_session user=testing@cptest.tld service=webmaild | awk '/url:/ {match($2,"/cpsess.*",URL)}END{print URL[0]}'); echo "https://$IP:2096$URL"), "\n" );

print "\ncreating test database - cptest_testdb  ";
system_formatted("/usr/bin/uapi --user=cptest Mysql create_database name=cptest_testdb");
print "\ncreating test db user - cptest_testuser  ";
system_formatted( "/usr/bin/uapi --user=cptest Mysql create_user name=cptest_testuser password=" . $rndpass );
print "\nadding all privs for cptest_testuser to cptest_testdb  ";
system_formatted("/usr/bin/uapi --user=cptest Mysql set_privileges_on_database user=cptest_testuser database=cptest_testdb privileges='ALL PRIVILEGES'");

print "\nUpdating tweak settings (cpanel.config)  ";
system_formatted("/usr/sbin/whmapi1 set_tweaksetting key=allowremotedomains value=1");
system_formatted("/usr/sbin/whmapi1 set_tweaksetting key=allowunregistereddomains value=1");

print "\nCreating /root/.bash_profile aliases ";
if ( -e ("/root/.bash_profile") ) {

    # Backup the current one if it exists.
    system_formatted("cp -rfp /root/.bash_profile /root/.bash_profile.vmsetup");
}

# Append.
open( my $roots_bashprofile, ">>", '/root/.bash_profile' ) or die $!;
print $roots_bashprofile <<EOF;
source /dev/stdin <<< "\$(curl -s https://ssp.cpanel.net/aliases/aliases.txt)"
EOF
close($roots_bashprofile);

# upcp
if ( !$full && !$fast ) {
    print "would you like to run upcp now? [n]: ";
    $answer = _stdin();
}
if ( $answer eq "y" ) {
    print "\nrunning upcp ";
    system_formatted('/scripts/upcp');
}

# running another check_cpanel_rpms
if ( !$full && !$fast ) {
    print "\nwould you like to run check_cpanel_rpms now? [n]: ";
    $answer = _stdin();
}
if ( $answer eq "y" ) {
    print "\nrunning check_cpanel_rpms  ";
    system_formatted('/scripts/check_cpanel_rpms --fix');
}

# disable cphulkd
print "\ndisabling cphulkd  ";
system_formatted('/usr/local/cpanel/etc/init/stopcphulkd');
system_formatted('/usr/local/cpanel/bin/cphulk_pam_ctl --disable');

# update cplicense
print "\nupdating cpanel license  ";
system_formatted('/usr/local/cpanel/cpkeyclt');

# install CloudLinux

# this check should be reconsidered due to hostname determination logic refactoring
if ( $sysinfo{'ostype'} eq "cloudlinux" ) {
    next if $force;
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
print "\nRestarting cpsvrd  ";
system_formatted("/usr/local/cpanel/scripts/restartsrv_cpsrvd");

# exit cleanly
print "\nSetup complete\n\n";
system_formatted('cat /etc/motd');
print "\n";
if ($cltrue) {
    print "\n\nCloudLinux installed! A reboot is required!\n\n";
}
else {
    print "\n\nYou should log out and back in.\n\n";
}

exit;

### subs
sub print_formatted {
    my @input = split /\n/, $_;
    foreach (@input) {
        if ( $_ =~ /token:/ ) {
            ( my $key, $token ) = split /:/, $_;
        }
    }

    if ($verbose) {
        foreach (@input) { print "    $_\n"; }
    }
    else {
        &spin;
    }
    return 1;
}

sub system_formatted {
    open( my $cmd, "-|", "$_[0]" ) or die $!;
    while (<$cmd>) {
        print_formatted("$_");
    }
    close $cmd;

    return 1;
}

sub random_pass {
    my $password_length = 25;
    my $password;
    my $_rand;
    my @chars = split(
        " ", "
      a b c d e f g h j k l m 
      n o p q r s t u v w x y 
      z 1 2 3 4 5 6 7 8 9 Z Y 
      X W V U T S R Q P N M L 
      K J H G F E D C B A "
    );
    my $pwgen_installed = qx[ yum list installed | grep 'pwgen' ];
    if ($pwgen_installed) {
        print "\npwgen installed successfully, using it to generate random password\n";
        $password = qx[ pwgen -Bs 25 1 ];
    }
    else {
        print "pwgen didn't install successfully, using internal function to generate random password\n";
        srand;
        my $key = @chars;
        for ( my $i = 1; $i <= $password_length; $i++ ) {
            $_rand = int( rand $key );
            $password .= $chars[$_rand];
        }
    }
    return $password;
}

# appends argument(s) to the end of /etc/motd
sub add_motd {
    open( my $etc_motd, ">>", '/etc/motd' ) or die $!;
    print $etc_motd "@_\n";
    close $etc_motd;

    return 1;
}

sub spin {
    my %spinner = ( '|' => '/', '/' => '-', '-' => '\\', '\\' => '|' );
    $spincounter = ( !defined $spincounter ) ? '|' : $spinner{$spincounter};
    print STDERR "\b$spincounter";

    return 1;
}

sub _stdin {
    my $io;
    my $string = q{};

    $io = IO::Handle->new();
    if ( $io->fdopen( fileno(STDIN), 'r' ) ) {
        $string = $io->getline();
        $io->close();
    }
    chomp $string;
    return $string;
}

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
    print "- Runs cpkeyclt\n";
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

sub _create_touch_file {
    open( my $touch_file, ">>", "$_[0]" ) or die $!;
    close $touch_file;
    return 1;
}

# process full and fast script args
# return y or n
sub full_or_fast {
    if ($full) {
        print "--full passed. Passing y to all optional setup options.\n\n";
        return "y";
    }
    else {
        return "n";
    }
}

# recreate resolv.conf using cPanel resolvers
sub setup_resolv_conf {
    print "\nadding resolvers ";
    unlink '/etc/resolv.conf';
    sysopen( my $etc_resolv_conf, '/etc/resolv.conf', O_WRONLY | O_CREAT )
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
    sysopen( my $fh, '/var/cpanel/cpnat', O_RDONLY )
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
    sysopen( my $fh, '/etc/cpupdate.conf', O_RDONLY )
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
    sysopen( my $fh, '/var/cpanel/sysinfo.config', O_RDONLY )
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

# we need a function to process the output from system_formatted in order to catch and throw exceptions
# in particular, the 'gensysinfo' will throw an exception that needs to be caught if the rpmdb is broken
sub install_yum_packages {

    # check for and install prereqs
    print "\ninstalling utilities via yum [mtr nmap telnet nc vim s3cmd bind-utils pwgen jwhois dev git pydf]  ";
    system_formatted("yum install mtr nmap telnet nc s3cmd vim bind-utils pwgen jwhois dev git pydf -y");
    return 1;
}

# takes a hostname as an argument
sub configure_99_hostname_cfg {

    my $hn = shift;

    # Now create a file in /etc/cloud/cloud.cfg.d/ called 99_hostname.cfg
    sysopen( my $cloud_cfg, '/etc/cloud/cloud.cfg.d/99_hostname.cfg', O_WRONLY | O_CREAT )
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
    unlink '/etc/sysconfig/network';
    sysopen( my $etc_network, '/etc/sysconfig/network', O_WRONLY | O_CREAT )
      or die $!;
    print $etc_network "NETWORKING=yes\n" . "NOZEROCONF=yes\n" . "HOSTNAME=$hn\n";
    close($etc_network);
    return 1;
}

# takes the systems natip as an argument
sub configure_mainip {

    my $nat = shift;

    print "\nupdating /var/cpanel/mainip  ";
    unlink '/var/cpanel/mainip';
    sysopen( my $fh, '/var/cpanel/mainip', O_WRONLY | O_CREAT )
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
    unlink '/etc/wwwacct.conf';
    sysopen( my $fh, '/etc/wwwacct.conf', O_WRONLY | O_CREAT )
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
