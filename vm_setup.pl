#!/usr/local/cpanel/3rdparty/bin/perl

# vm_setup.pl

use strict;
use warnings;
use Getopt::Long;
use Fcntl;
$| = 1;

my $VERSION = '0.5.5';

# get opts
my ($ip, $natip, $help, $fast, $full, $force, $cltrue, $answer);
GetOptions (
	"help" => \$help,
	"full" => \$full,
	"fast" => \$fast,
	"force" => \$force,
	"installcl" => \$cltrue,
);

# add resolvers - although we shouldn't be using Google's DNS (or any public resolvers)
print "adding resolvers\n";
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
    print "--full: Passes yes to all optional setup functions\n";
    print "--installcl: Installs CloudLinux(can take a while and requires reboot)\n";
    print "Full list of things this does: \n";
    print "-------------- \n";
    print "- Installs common packages\n";
    print "- Sets hostname\n";
    print "- Updates /var/cpanel/cpanel.config (Tweak Settings)\n";
    print "- Performs basic setup wizard\n";
    print "- Fixes /etc/hosts\n";
    print "- Fixes screen permissions\n";
    print "- Runs cpkeyclt\n";
    print "- Creates test accounts\n";
    print "- Disables cphulkd\n";
    print "- Creates access hash\n";
    print "- Updates motd\n";
    print "- Creates /root/.bash_profile with helpful aliases\n";
    print "- Runs upcp (optional)\n";
    print "- Runs check_cpanel_rpms --fix (optional)\n";
    print "- Downloads and runs cldeploy (Installs CloudLinux) --installcl (optional)\n";
    exit;
}

# generate random password
my $rndpass = &random_pass();  
# generate unique hostnames from OS type, Version and cPanel Version info and time.
my $time=time;
my %ostype = (
        "CentOS" => "C",
        "CloudLinux" => "CL",
);
my $OS=qx[ cat /etc/redhat-release ];
my ($Flavor,$OSVer)=(split(/\s+/,$OS))[0,2];
$OSVer = substr($OSVer,0,3);
$OSVer =~ s/\.//g;
my $cPanelVer=qx[ cat /usr/local/cpanel/version ];
chomp($cPanelVer);
$cPanelVer=substr($cPanelVer,3);
my $hostname = $ostype{$Flavor} . $OSVer . "-" . $cPanelVer . "-" . $time . ".cpanel.vm";

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
print "creating lock file\n"; 
system_formatted ("touch /root/vmsetup.lock");

# check for and install prereqs
print "installing utilities via yum [mtr nmap telnet nc vim s3cmd bind-utils pwgen jwhois dev git pydf]\n";
system_formatted ("yum install mtr nmap telnet nc s3cmd vim bind-utils pwgen jwhois dev git pydf -y");

# set hostname
print "setting hostname\n";
# Now create a file in /etc/cloud/cloud.cfg.d/ called 99_hostname.cfg
sysopen (my $cloud_cfg, '/etc/cloud/cloud.cfg.d/99_hostname.cfg', O_WRONLY|O_CREAT) or
	die print_formatted ("$!");
	print $cloud_cfg "#cloud-config\n" . 
		"hostname: $hostname\n";
close ($cloud_cfg);  

system_formatted ("/usr/local/cpanel/bin/set_hostname $hostname");

# set /etc/sysconfig/network
print "updating /etc/sysconfig/network\n";
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

##############################################################################################
# NOTE: Running /var/cpanel/cpnat is really no longer necessary on openstack VM's.  
# This is because of the double-nat configuration these servers have.  
# I'm commenting out this code for now.  If it turns out that it is causing problems, I'll
# put it all back. 
##############################################################################################

# Move the current /var/cpanel/cpnat file out of the way for a backup.  
#print "moving current /var/cpanel/cpnat file to /var/cpanel/cpnat.vmsetup\n";
#system_formatted ("mv /var/cpanel/cpnat /var/cpanel/cpnat.vmsetup");
#else {
#   $ip="208.74.121.106";
#   ($natip)=(split(/\s+/,qx[ cat /etc/wwwacct.conf | grep 'ADDR ' ]))[1];
#   chomp($natip);
#   sysopen (my $cpnat, '/var/cpanel/cpnat', O_WRONLY|O_CREAT) or die print_formatted ("$!");
#   print $cpnat "$natip $ip\n";
#   close ($cpnat);
#}
# run /scripts/build_cpnat
#print "running build_cpnat\n";
#system_formatted ("/scripts/build_cpnat");

# fix /var/cpanel/mainip file because for some reason it has an old value in it
system_formatted ("ip=`cat /etc/wwwacct.conf | grep 'ADDR ' | awk '{print \$2}'`; echo -n \$ip > /var/cpanel/mainip");

# create .whostmgrft
print "creating /etc/.whostmgrft\n";
sysopen (my $etc_whostmgrft, '/etc/.whostmgrft', O_WRONLY|O_CREAT) or
    die print_formatted ("$!");
close ($etc_whostmgrft);

# correct wwwacct.conf
print "correcting /etc/wwwacct.conf\n";
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
print "correcting /etc/hosts\n";
unlink '/etc/hosts';
sysopen (my $etc_hosts, '/etc/hosts', O_WRONLY|O_CREAT) or
    die print_formatted ("$!");
    print $etc_hosts "127.0.0.1		localhost localhost.localdomain localhost4 localhost4.localdomain4\n" .
                     "::1		localhost localhost.localdomain localhost6 localhost6.localdomain6\n" .
                     "$ip		daily $hostname\n";
close ($etc_hosts);

# fix screen perms
print "fixing screen perms\n";
system_formatted ('/bin/rpm --setugids screen && /bin/rpm --setperms screen');

# make accesshash
print "making access hash\n";
$ENV{'REMOTE_USER'} = 'root';
system_formatted ('/usr/local/cpanel/bin/realmkaccesshash');

print "Installing CDB_file.pm Perl Module\n";
system_formatted ('/usr/local/cpanel/bin/cpanm --force CDB_File');

# create test account
print "creating test account - cptest\n";
# <domain> <username> <password> <quota> <theme> <ip[y/n]> <cgi[y/n]> <frontpage [always n]> <maxftp> <maxsql> <maxpop> <maxlist> <maxsub> <bwlimit> <has_shell[y/n]> <owner [root|reseller]> <plan> <maxpark> <maxaddon> <featurelist>
# NOT INCLUDED above is: <contactemail> <use_registered_nameservers> <language>
system_formatted ('yes |/usr/local/cpanel/scripts/wwwacct cptest.tld cptest ' . $rndpass . ' 1000 paper_lantern n y n 10 10 10 10 10 1000 n root default 10 10 default');
print "creating test email - testing\@cptest.tld\n";
system_formatted ('/usr/local/cpanel/scripts/addpop testing@cptest.tld ' . $rndpass);
print "creating test database - cptest_testdb\n";
system_formatted ("mysql -e 'create database cptest_testdb'");
print "creating test db user - cptest_testuser\n";
system_formatted ("mysql -e 'create user \"cptest_testuser\" identified by \" $rndpass \"'");
print "adding all privs for cptest_testuser to cptest_testdb\n";
system_formatted ("mysql -e 'grant all on cptest_testdb.* TO cptest_testuser'");
system_formatted ("mysql -e 'FLUSH PRIVILEGES'");
print "mapping cptest_testuser and cptest_testdb to cptest account\n";
system_formatted ("/usr/local/cpanel/bin/dbmaptool cptest --type mysql --dbusers 'cptest_testuser' --dbs 'cptest_testdb'");

print "Updating tweak settings (cpanel.config)...\n";
system_formatted ("/usr/bin/replace allowremotedomains=0 allowremotedomains=1 allowunregistereddomains=0 allowunregistereddomains=1 -- /var/cpanel/cpanel.config");

print "Creating /root/.bash_profile aliases...\n";
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
system_formatted ("source /root/.bash_profile");

# upcp
if (!$full && !$fast) { 
   print "would you like to run upcp now? [n] \n";
   chomp ($answer = <STDIN>);
}
if ($answer eq "y") {
    print "\nrunning upcp \n ";
    system_formatted ('/scripts/upcp');
}

# running another check_cpanel_rpms
if (!$full && !$fast) { 
   print "would you like to run check_cpanel_rpms now? [n] \n";
   chomp ($answer = <STDIN>);
}
if ($answer eq "y") {
    print "\nrunning check_cpanel_rpms \n ";
    system_formatted ('/scripts/check_cpanel_rpms --fix');
}

print "Installing root's crontab...\n";
sysopen (my $roots_cron, '/var/spool/cron/root', O_WRONLY|O_CREAT) or die print_formatted ("$!");
print $roots_cron 
"# This crontab was created by vm_setup script.
8,23,38,53 * * * * /usr/local/cpanel/whostmgr/bin/dnsqueue > /dev/null 2>&1
30 */4 * * * /usr/bin/test -x /usr/local/cpanel/scripts/update_db_cache && /usr/local/cpanel/scripts/update_db_cache
*/5 * * * * /usr/local/cpanel/bin/dcpumon >/dev/null 2>&1
56 0 * * * /usr/local/cpanel/whostmgr/docroot/cgi/cpaddons_report.pl --notify
7 0 * * * /usr/local/cpanel/scripts/upcp --cron
0 1 * * * /usr/local/cpanel/scripts/cpbackup
35 * * * * /usr/bin/test -x /usr/local/cpanel/bin/tail-check && /usr/local/cpanel/bin/tail-check
30 */2 * * * /usr/local/cpanel/bin/mysqluserstore >/dev/null 2>&1
15 */2 * * * /usr/local/cpanel/bin/dbindex >/dev/null 2>&1
45 */4 * * * /usr/bin/test -x /usr/local/cpanel/scripts/update_mailman_cache && /usr/local/cpanel/scripts/update_mailman_cache
15 */6 * * * /usr/local/cpanel/scripts/recoverymgmt >/dev/null 2>&1
15 */6 * * * /usr/local/cpanel/scripts/autorepair recoverymgmt >/dev/null 2>&1
30 5 * * * /usr/local/cpanel/scripts/optimize_eximstats > /dev/null 2>&1
0 2 * * * /usr/local/cpanel/bin/backup
2,58 * * * * /usr/local/bandmin/bandmin
0 0 * * * /usr/local/bandmin/ipaddrmap\n";
close ($roots_cron);

print "updating /etc/motd\n";
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

# fix roundcube by forcing a re-install
print "Fixing roundcube by forcing a re-install\n";
system_formatted ('/usr/local/cpanel/bin/update-roundcube --force');

# disables cphulkd
print "disables cphulkd\n";
system_formatted ('/usr/local/cpanel/etc/init/stopcphulkd');
system_formatted ('/usr/local/cpanel/bin/cphulk_pam_ctl --disable');

# update cplicense
print "updating cpanel license\n";
system_formatted ('/usr/local/cpanel/cpkeyclt');

# install CloudLinux
if ($cltrue) { 
    my $InstLVE=0;
    my $InstPHPSelector=0;
    my $InstCageFS=0;
    print "You selected CloudLinux. Do you want to also install: \n";
    print "LVE Manager (Y/n): ";
    $InstLVE=<STDIN>;
    chomp($InstLVE);
    $InstLVE=uc($InstLVE);
    if ($InstLVE eq "" or $InstLVE eq "Y") { $InstLVE=1; } 
    print "PHP Selector (Y/n): ";
    $InstPHPSelector=<STDIN>;
    chomp($InstPHPSelector);
    $InstPHPSelector=uc($InstPHPSelector);
    if ($InstPHPSelector eq "" or $InstPHPSelector eq "Y") { $InstPHPSelector=1; } 
    print "CageFS (Y/n): ";
    $InstCageFS=<STDIN>;
    chomp($InstCageFS);
    $InstCageFS=uc($InstCageFS);
    if ($InstCageFS eq ""or $InstCageFS eq "Y") { $InstCageFS=1; } 
	# Remove /var/cpanel/nocloudlinux touch file (if it exists)
	if (-e("/var/cpanel/nocloudlinux")) { 
		unlink("/var/cpanel/nocloudlinux");
	}
	system_formatted ("wget http://repo.cloudlinux.com/cloudlinux/sources/cln/cldeploy");
	system_formatted ("sh cldeploy -k 42-2efe234f2ae327824e879a2bec87fc59");
    if ($InstLVE) { 
        system_formatted ("yum -y install lvemanager");
    }
    if ($InstCageFS) { 
        system_formatted ("yum -y install cagefs");
    }
    if ($InstPHPSelector) { 
        system_formatted ("yum -y groupinstall alt-php");
        system_formatted ("yum -y update cagefs lvemanager");
    }
    system_formatted ("/usr/local/cpanel/bin/cloudlinux_system_install -k");
}

# restart cpsrvd 
print "Restarting cpsvrd...\n";
system_formatted ("/usr/local/cpanel/scripts/restartsrv_cpsrvd");

# exit cleanly
print "Setup complete\n\n";
system_formatted ('cat /etc/motd');
print "\n"; 
if ($cltrue) { 
	print "\n\nCloudLinux installed! A reboot is required!\n\n";
}

exit;

### subs
sub print_formatted {
    my @input = split /\n/, $_[0];
    foreach (@input) { print "    $_\n"; }
}

sub system_formatted {
    open (my $cmd, "-|", "$_[0]");
    while (<$cmd>) {
        print_formatted("$_");
    }
    close $cmd;
}

sub random_pass { 
	my $password_length=12;
	my $password;
	my $_rand;
	my @chars = split(" ", "
      a b c d e f g h j k l m 
      n o p q r s t u v w x y 
      z - _ % # ! 1 2 3 4 5 6 
      7 8 9 Z Y X W V U T S R 
      Q P N M L K J H G F E D 
      C B A = + "
   );
	srand;
	my $key=@chars;
	for (my $i=1; $i <= $password_length ;$i++) {
		$_rand = int(rand $key);
		$password .= $chars[$_rand];
	}
	return $password;
}
