#!/usr/bin/perl

# vm_setup.pl

use strict;
use warnings;
use Getopt::Long;
use Fcntl;
$| = 1;

my $VERSION = '0.4.2';

# get opts
my ($ip, $natip, $help, $fast, $full, $force, $cltrue, $answer);
GetOptions (
	"help" => \$help,
	"full" => \$full,
	"fast" => \$fast,
	"force" => \$force,
	"installcl" => \$cltrue,
);

# Install Data::Validate::IP Perl module since it's necessary to validate an IP address.
system_formatted ("/usr/local/cpanel/bin/cpanm Data::Validate::IP");

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
    print "- Sets resolvers\n";
    print "- Builds/updates /var/cpanel/cpnat\n";
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
    print "- Installs Task::Cpanel::Core (optional)\n\n";
    exit;
}

# generate random password
my $rndpass = &random_pass();  
my $time=time;
my $hostname="daily".$time.".cpanel.vm";

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
print "installing utilities via yum [mtr nmap telnet nc s3cmd bind-utils jwhois dev git pydf]\n";
system_formatted ("yum install mtr nmap telnet nc s3cmd bind-utils jwhois dev git pydf -y");

# set hostname
print "setting hostname\n";
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

# add resolvers - WE SHOULD NOT BE USING GOOGLE DNS!!! (or any public resolvers)
# Well, seems as though we turned off 208.74.121.103 as a resolver.  So going to OpenDNS for now.
print "adding resolvers\n";
unlink '/etc/resolv.conf';
sysopen (my $etc_resolv_conf, '/etc/resolv.conf', O_WRONLY|O_CREAT) or
    die print_formatted ("$!");
    print $etc_resolv_conf "search cpanel.net\n" . "nameserver 208.67.220.220\n" . "nameserver 208.67.222.222\n";
close ($etc_resolv_conf);

# run /scripts/build_cpnat
# Move the current /var/cpanel/cpnat file out of the way.  
system_formatted ("mv /var/cpanel/cpnat /var/cpanel/cpnat.vmsetup");
print "running build_cpnat\n";
system_formatted ("/scripts/build_cpnat");
# IF THE ABOVE COMMAND FAILS, THEN WE DON'T KNOW $ip or $natip!!! GET IT FROM /etc/wwwacct.conf
if (-e("/var/cpanel/cpnat")) { 
   chomp ( $ip = qx(cat /var/cpanel/cpnat | awk '{print\$2}') );
   chomp ( $natip = qx(cat /var/cpanel/cpnat | awk '{print\$1}') );
}
else {
   $ip="208.74.121.106";
   ($natip)=(split(/\s+/,qx[ cat /etc/wwwacct.conf | grep 'ADDR ' ]))[1];
   chomp($natip);
   sysopen (my $cpnat, '/var/cpanel/cpnat', O_WRONLY|O_CREAT) or die print_formatted ("$!");
   print $cpnat "$natip $ip\n";
   close ($cpnat);
}

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
my $OSVER = `cat /etc/redhat-release`;
my $MINUID=500;
if ($OSVER =~ 7.1) { 
   $MINUID=1000;
}
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
                            "MINUID $MINUID\n" .
                            "HOMEMATCH home\n" .
                            "NSTTL 86400\n" .
                            "TTL 14400\n" .
                            "DEFMOD paper_lantern\n" .
                            "SCRIPTALIAS y\n" .
                            "CONTACTPAGER\n" .
                            "MINUID\n" .
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
#system_formatted ('/bin/rpm --setperms screen');
#system_formatted ('/bin/rpm --setugids screen');
system_formatted ('/bin/rpm --setugids screen && /bin/rpm --setperms screen');

# make accesshash
print "making access hash\n";
$ENV{'REMOTE_USER'} = 'root';
system_formatted ('/usr/local/cpanel/bin/realmkaccesshash');

# create test account
print "creating test account - cptest\n";
system_formatted ('yes |/usr/local/cpanel/scripts/wwwacct cptest.tld cptest ' . $rndpass . ' 1000 paper_lantern n y 10 10 10 10 10 10 10 n');
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
if (!(-e("/root/.bash_profile"))) {
   sysopen (my $roots_bashprofile, '/root/.bash_profile', O_WRONLY|O_CREAT) or die print_formatted ("$!");
   print $roots_bashprofile <<EOF;
export EDITOR=vi
export VISUAL=vi
alias ll="ls -alh"
alias dir="ll | grep '^d'"
alias ssp="curl -sk https://ssp.cpanel.net/run | sh"
alias acctinfo="/usr/local/cpanel/3rdparty/bin/perl <(curl -s https://raw.githubusercontent.com/cPanelPeter/acctinfo/master/acctinfo)"
alias jsonpp='function _jsonpp() { cat \$1 | /usr/local/cpanel/3rdparty/perl/514/bin/json_xs; }; _jsonpp'
EOF
   close ($roots_bashprofile);
}

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

# install Task::Cpanel::Core
if (!$full && !$fast) { 
   print "would you like to install Task::Cpanel::Core? [n] \n";
   chomp ($answer = <STDIN>);
}
if ($answer eq "y") {
    print "\ninstalling Task::Cpanel::Core\n ";
    system_formatted ('/scripts/perlinstaller Task::Cpanel::Core');
}

print "Installing root's crontab if missing...\n";
if (!(-e("/var/spool/cron/root")) or -s("/var/spool/cron/root")) { 
	sysopen (my $roots_cron, '/var/spool/cron/root', O_WRONLY|O_CREAT) or 
		die print_formatted ("$!");
	print $roots_cron "8,23,38,53 * * * * /usr/local/cpanel/whostmgr/bin/dnsqueue > /dev/null 2>&1
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
}

system("grep -A1 'Disabling selinux' /var/log/boot.log | grep -v 'Disabling selinux' > /root/vmsetup.tmp");
my $SERVER_IP=qx[ tail -1 /root/vmsetup.tmp ];
chomp($SERVER_IP);

print "updating /etc/motd\n";
unlink '/etc/motd';
sysopen (my $etc_motd, '/etc/motd', O_WRONLY|O_CREAT) or
    die print_formatted ("$!");
    if (is_ipv4($SERVER_IP)) { 
        print $etc_motd "VM Setup Script created the following test accounts:\n" .
                     "WHM: https://$SERVER_IP:2087 - user=root - pass=cpanel1\n" . 
                     "cPanel: https://$SERVER_IP:2083/login?user=cptest&pass=" . $rndpass . " (Domain: cptest.tld cPanel Account: cptest)\n" .
                     "Webmail: https://$SERVER_IP:2096/login?user=testing\@cptest.tld&pass=" . $rndpass . "\n\n" . 
                     "The following aliases have also been setup: ssp, acctinfo jsonpp\n\n";
    }
    else { 
        print $etc_motd "VM Setup Script created the following test accounts:\n" .
                     "WHM: user=root - pass=cpanel1\n" . 
                     "cPanel: user=cptest - pass=" . $rndpass . "(Domain: cptest.tld\n" .
                     "Webmail: user=testing\@cptest.tld - pass=" . $rndpass . "\n\n" . 
                     "The following aliases have also been setup: ssp, acctinfo jsonpp\n\n";
    }
close ($etc_motd);

# disables cphulkd
print "disables cphulkd\n";
system_formatted ('/usr/local/cpanel/etc/init/stopcphulkd');
system_formatted ('/usr/local/cpanel/bin/cphulk_pam_ctl --disable');

# update cplicense
print "updating cpanel license\n";
system_formatted ('/usr/local/cpanel/cpkeyclt');

# move /etc/cpsources.conf out of the way if it exists
if (-e("/etc/cpsources.conf")) { 
   print "Found /etc/cpsources.conf file, moving it out of the way!\n";
   system_formatted ("mv /etc/cpsources.conf /etc/cpsources.conf.vmsetup");
}

# install CloudLinux
if ($cltrue) { 
	# Remove /var/cpanel/nocloudlinux touch file (if it exists)
	if (-e("/var/cpanel/nocloudlinux")) { 
		unlink("/var/cpanel/nocloudlinux");
	}
	system_formatted ("wget http://repo.cloudlinux.com/cloudlinux/sources/cln/cldeploy");
	system_formatted ("sh cldeploy -k 42-2efe234f2ae327824e879a2bec87fc59");
}

# exit cleanly
print "setup complete\n\n";
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
