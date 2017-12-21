#!/usr/local/cpanel/3rdparty/bin/perl

# vm_setup.pl

use strict;
use warnings;
use Getopt::Long;
use Fcntl;
$| = 1;

my $VERSION = '0.5.9';

# get opts
my ($ip, $natip, $help, $fast, $full, $force, $cltrue, $answer, $verbose);
our $spincounter;
my $InstPHPSelector=0;
my $InstCageFS=0;

GetOptions (
	"help" => \$help,
	"verbose" => \$verbose,
	"full" => \$full,
	"fast" => \$fast,
	"force" => \$force,
	"installcl" => \$cltrue,
);

# add resolvers - although we shouldn't be using Google's DNS (or any public resolvers)
print "\nadding resolvers ";
unlink '/etc/resolv.conf';
sysopen (my $etc_resolv_conf, '/etc/resolv.conf', O_WRONLY|O_CREAT) or
    die print_formatted ("$!");
    print $etc_resolv_conf "search cpanel.net\n" . "nameserver 208.74.121.50\n" . "nameserver 208.74.125.59\n";
close ($etc_resolv_conf);

# print header
print "\nVM Server Setup Script\n" .
      "Version: $VERSION\n" .
      "\n";
if ($help) {
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

# generate unique hostnames from OS type, Version and cPanel Version info and time.
my ($OS_RELEASE, $OS_TYPE,$OS_VERSION) = get_os_info();
my $time=time;
my %ostype = (
        "centos" => "c",
        "cloudlinux" => "cl",
);
my $Flavor = $ostype{$OS_TYPE};
my $versionstripped = $OS_VERSION;
$versionstripped =~ s/\.//g;
my $cpVersion=qx[ cat /usr/local/cpanel/version ];
chomp($cpVersion);
$cpVersion =~ s/\./-/g;
$cpVersion = substr($cpVersion,3);
my $hostname = $Flavor.$versionstripped."-".$cpVersion."-".$time.".cpanel.vm";

### and go

if (-e "/root/vmsetup.lock") {
    if (!$force)
    {
        print "/root/vmsetup.lock exists. This script may have already been run. Use --force to bypass. Exiting...\n";
        exit;
    } else
    {
        print "/root/vmsetup.lock exists. --force passed. Ignoring...\n";
    }
}

if($full) {
    print "--full passed. Passing y to all optional setup options.\n\n";
    chomp ($answer="y");
}
if($fast) {
    print "--fast passed. Skipping all optional setup options.\n\n";
    chomp ($answer="n");
}

# create lock file
print "\ncreating lock file "; 
system_formatted ("touch /root/vmsetup.lock");

# check for and install prereqs
print "\ninstalling utilities via yum [mtr nmap telnet nc vim s3cmd bind-utils pwgen jwhois dev git pydf]  ";
system_formatted ("yum install mtr nmap telnet nc s3cmd vim bind-utils pwgen jwhois dev git pydf -y");

# set hostname
print "\nsetting hostname to $hostname  ";
# Now create a file in /etc/cloud/cloud.cfg.d/ called 99_hostname.cfg
sysopen (my $cloud_cfg, '/etc/cloud/cloud.cfg.d/99_hostname.cfg', O_WRONLY|O_CREAT) or
	die print_formatted ("$!");
	print $cloud_cfg "#cloud-config\n" . 
		"hostname: $hostname\n";
close ($cloud_cfg);  

system_formatted ("/usr/local/cpanel/bin/set_hostname $hostname");

# generate random password
my $rndpass = &random_pass();  

# set /etc/sysconfig/network
print "\nupdating /etc/sysconfig/network  ";
unlink '/etc/sysconfig/network';
sysopen (my $etc_network, '/etc/sysconfig/network', O_WRONLY|O_CREAT) or
    die print_formatted ("$!");
    print $etc_network "NETWORKING=yes\n" .
                     "NOZEROCONF=yes\n" .
                     "HOSTNAME=$hostname\n";
close ($etc_network);

if (-e("/var/cpanel/cpnat")) { 
   chomp ( $ip = qx(cat /var/cpanel/cpnat | awk '{print\$2}') );
   chomp ( $natip = qx(cat /var/cpanel/cpnat | awk '{print\$1}') );
}

# fix /var/cpanel/mainip file because for some reason it has an old value in it
system_formatted ("ip=`cat /etc/wwwacct.conf | grep 'ADDR ' | awk '{print \$2}'`; echo -n \$ip > /var/cpanel/mainip");

# create .whostmgrft
print "\ncreating /etc/.whostmgrft  ";
sysopen (my $etc_whostmgrft, '/etc/.whostmgrft', O_WRONLY|O_CREAT) or
    die print_formatted ("$!");
close ($etc_whostmgrft);

# correct wwwacct.conf
print "\ncorrecting /etc/wwwacct.conf  ";
unlink '/etc/wwwacct.conf';
sysopen (my $etc_wwwacct_conf, '/etc/wwwacct.conf', O_WRONLY|O_CREAT) or
    die print_formatted ("$!");
    print $etc_wwwacct_conf "HOST $hostname\n" .
                            "ADDR $natip\n" .
                            "HOMEDIR /home\n" .
                            "ETHDEV eth0\n" .
                            "NS ns1.os.cpanel.vm\n" .
                            "NS2 ns2.os.cpanel.vm\n" .
                            "NS3\n" .
                            "NS4\n" .
                            "HOMEMATCH home\n" .
                            "NSTTL 86400\n" .
                            "TTL 14400\n" .
                            "DEFMOD paper_lantern\n" .
                            "SCRIPTALIAS y\n" .
                            "CONTACTPAGER\n" .
                            "CONTACTEMAIL\n" .
                            "LOGSTYLE combined\n" .
                            "DEFWEBMAILTHEME paper_lantern\n";
close ($etc_wwwacct_conf);

# correct /etc/hosts
print "\ncorrecting /etc/hosts  ";
unlink '/etc/hosts';
sysopen (my $etc_hosts, '/etc/hosts', O_WRONLY|O_CREAT) or
    die print_formatted ("$!");
    print $etc_hosts "127.0.0.1		localhost localhost.localdomain localhost4 localhost4.localdomain4\n" .
                     "::1		localhost localhost.localdomain localhost6 localhost6.localdomain6\n" .
                     "$ip		daily $hostname\n";
close ($etc_hosts);

# fix screen perms
print "\nfixing screen perms  ";
system_formatted ('/bin/rpm --setugids screen && /bin/rpm --setperms screen');

# create api token
print "\ncreating api token";
$ENV{'REMOTE_USER'} = 'root';
system_formatted ('whmapi1 api_token_create token_name=setup acl-1=all');

print "\nInstalling CDB_file.pm Perl Module  ";
system_formatted ('/usr/local/cpanel/bin/cpanm --force CDB_File');

# create test account
print "\ncreating test account - cptest  ";
system_formatted ('/usr/sbin/whmapi1 createacct username=cptest domain=cptest.tld password=" . $rndpass ." pkgname=my_package savepgk=1 maxpark=unlimited maxaddon=unlimited');
print "\ncreating test email - testing\@cptest.tld  ";
system_formatted ('/usr/bin/uapi --user=cptest Email add_pop email=testing@cptest.tld password=" . $rndpass . "');
print "\ncreating test database - cptest_testdb  ";
system_formatted ("/usr/bin/uapi --user=cptest Mysql create_database name=cptest_testdb");
print "\ncreating test db user - cptest_testuser  ";
system_formatted ("/usr/bin/uapi --user=cptest Mysql create_user name=cptest_testuser password=". $rndpass );
print "\nadding all privs for cptest_testuser to cptest_testdb  ";
system_formatted ("/usr/bin/uapi --user=cptest Mysql set_privileges_on_database user=cptest_testuser database=cptest_testdb privileges='ALL PRIVILEGES'");

print "\nUpdating tweak settings (cpanel.config)  ";
system_formatted ("/usr/sbin/whmapi1 set_tweaksetting key=allowremotedomains value=1");
system_formatted ("/usr/sbin/whmapi1 set_tweaksetting key=allowunregistereddomains value=1");

print "\nCreating /root/.bash_profile aliases ";
if (-e("/root/.bash_profile")) {
   # Backup the current one if it exists. 
   system_formatted ("cp -rfp /root/.bash_profile /root/.bash_profile.vmsetup");
}
# Append.
open(roots_bashprofile, ">>/root/.bash_profile") or die print_formatted ("$!");
print roots_bashprofile <<EOF;
source /dev/stdin <<< "\$(curl -s https://ssp.cpanel.net/aliases/aliases.txt)"
EOF
close (roots_bashprofile);

# upcp
if (!$full && !$fast) { 
   print "would you like to run upcp now? [n]: ";
   chomp ($answer = <STDIN>);
}
if ($answer eq "y") {
    print "\nrunning upcp ";
    system_formatted ('/scripts/upcp');
}

# running another check_cpanel_rpms
if (!$full && !$fast) { 
   print "\nwould you like to run check_cpanel_rpms now? [n]: ";
   chomp ($answer = <STDIN>);
}
if ($answer eq "y") {
    print "\nrunning check_cpanel_rpms  ";
    system_formatted ('/scripts/check_cpanel_rpms --fix');
}

print "\nupdating /etc/motd  ";
unlink '/etc/motd';
my $etc_motd;
sysopen ($etc_motd, '/etc/motd', O_WRONLY|O_CREAT) or die print_formatted ("$!");
print $etc_motd "VM Setup Script created the following test accounts:\n\n" .
	"WHM: user: root - pass: cpanel1\n" .
	"cPanel: user: cptest - pass: " . $rndpass . "\n(Domain: cptest.tld cPanel Account: cptest)\n" .
	"Webmail: user: testing\@cptest.tld - pass: " . $rndpass . "\n\n" . 

    "WHM - https://" . $ip . ":2087\n" . 
    "cPanel - https://" . $ip . ":2083\n" . 
    "Webmail - https://" . $ip . ":2096\n";
close ($etc_motd);

# disable cphulkd
print "\ndisabling cphulkd  ";
system_formatted ('/usr/local/cpanel/etc/init/stopcphulkd');
system_formatted ('/usr/local/cpanel/bin/cphulk_pam_ctl --disable');

# update cplicense
print "\nupdating cpanel license  ";
system_formatted ('/usr/local/cpanel/cpkeyclt');

# install CloudLinux
if ($OS_TYPE eq "cloudlinux" and !$force) { 
    print "\nCloudLinux already detected, no need to install CloudLinux.  "; 
	# No need to install CloudLinux. It's already installed
	$cltrue = 0;
}
if ($cltrue) { 
	# Remove /var/cpanel/nocloudlinux touch file (if it exists)
	if (-e("/var/cpanel/nocloudlinux")) { 
        print "\nremoving /var/cpanel/nocloudlinux touch file  ";
		unlink("/var/cpanel/nocloudlinux");
	}
    print "\ndownloading cldeploy shell file  ";
	system_formatted ("wget http://repo.cloudlinux.com/cloudlinux/sources/cln/cldeploy");
    print "\nexecuting cldeploy shell file (Note: this runs a upcp and can take time)  ";
	my $clDeploy=qx[ echo | sh cldeploy -k 42-2efe234f2ae327824e879a2bec87fc59 ; echo ];
	print "\ninstalling CageFS  ";
    system_formatted ("echo | yum -y install cagefs");
	print "\ninitializing CageFS  ";
    system_formatted ("echo | cagefsctl --init");
	print "\ninstalling PHP Selector  ";
    system_formatted ("echo | yum -y groupinstall alt-php");
	print "\nupdating CageFS/LVE Manager  ";
    system_formatted ("echo | yum -y update cagefs lvemanager");
}

# restart cpsrvd 
print "\nRestarting cpsvrd  ";
system_formatted ("/usr/local/cpanel/scripts/restartsrv_cpsrvd");

# exit cleanly
print "\nSetup complete\n\n";
system_formatted ('cat /etc/motd');
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
    my @input = split /\n/, $_[0];
	if ($verbose) { 
	    foreach (@input) { print "    $_\n"; }
	}
    else { 
        &spin;
    }
}

sub system_formatted {
    open (my $cmd, "-|", "$_[0]");
    while (<$cmd>) {
        print_formatted("$_");
    }
    close $cmd;
}

sub random_pass { 
	my $password_length=25;
	my $password;
	my $_rand;
	my @chars = split(" ", "
      a b c d e f g h j k l m 
      n o p q r s t u v w x y 
      z 1 2 3 4 5 6 7 8 9 Z Y 
      X W V U T S R Q P N M L 
      K J H G F E D C B A "
   );
    my $pwgen_installed=qx[ yum list installed | grep 'pwgen' ];
    if ($pwgen_installed) { 
        print "\npwgen installed successfully, using it to generate random password\n";
        $password = `pwgen -Bs 15 1`;
    } 
    else {     
        print "pwgen didn't install successfully, using internal function to generate random password\n";
	    srand;
	    my $key=@chars;
	    for (my $i=1; $i <= $password_length ;$i++) {
		    $_rand = int(rand $key);
		    $password .= $chars[$_rand];
	    }
    }
	return $password;
}

sub get_os_info {
    my $ises = 0;
    my $version;
    my $os      = "UNKNOWN";
    my $release = "UNKNOWN";
    my $os_release_file;
    foreach my $test_release_file ( 'CentOS-release', 'redhat-release', 'system-release' ) {
        if ( -e '/etc/' . $test_release_file ) {
            if ( ( ($os) = $test_release_file =~ m/^([^\-_]+)/ )[0] ) {
                $os = lc $os;
                $os_release_file = '/etc/' . $test_release_file;
                if ( $os eq 'system' ) {
                    $os = 'amazon';
                }
                last;
            }
        }
    }
    if ( open my $fh, '<', $os_release_file ) {
        my $line = readline $fh;
        close $fh;
        chomp $line;
        if ( length $line >= 4 ) { $release = $line; }
        if ( $line =~ m/(?:Corporate|Advanced\sServer|Enterprise|Amazon)/i ) { $ises    = 1; }
        elsif ( $line =~ /CloudLinux|CentOS/i ) { $ises    = 2; }
        if ( $line =~ /(\d+\.\d+)/ ) { $version = $1; }
        elsif ( $line =~ /(\d+)/ )      { $version = $1; }
        if ( $line =~ /(centos|cloudlinux|amazon)/i ) { $os = lc $1; }
    }
    return ( $release, $os, $version, $ises );
}

sub spin {
    my %spinner = ( '|' => '/', '/' => '-', '-' => '\\', '\\' => '|' );
    $spincounter = ( !defined $spincounter ) ? '|' : $spinner{$spincounter};
    print STDERR "\b$spincounter";
}

