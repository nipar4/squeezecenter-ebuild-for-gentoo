package Slim::Utils::MySQLHelper;

# $Id: MySQLHelper.pm 17876 2008-03-13 18:21:05Z mherger $

=head1 NAME

Slim::Utils::MySQLHelper

=head1 SYNOPSIS

Slim::Utils::MySQLHelper->init

=head1 DESCRIPTION

Helper class for launching MySQL, installing the system tables, etc.

=head1 METHODS

=cut

use strict;
use base qw(Class::Data::Inheritable);
use DBI;
use DBI::Const::GetInfoType;
use File::Path;
use File::Slurp;
use File::Spec::Functions qw(:ALL);
use File::Which qw(which);
use Proc::Background;
use Template;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Prefs;
use Slim::Utils::SQLHelper;
use Slim::Utils::Prefs;

{
        my $class = __PACKAGE__;

        for my $accessor (qw(confFile mysqlDir pidFile socketFile needSystemTables processObj)) {

                $class->mk_classdata($accessor);
        }
}

my $log = logger('database.mysql');

my $prefs = preferences('server');

my $OS  = Slim::Utils::OSDetect::OS();

my $serviceName = 'SqueezeMySQL';

=head2 init()

Initializes the entire MySQL subsystem - creates the config file, and starts the server.

=cut

sub init {
	my $class = shift;

	# Check to see if our private port is being used. If not, we'll assume
	# the user has setup their own copy of MySQL.
	if ($prefs->get('dbsource') !~ /port=9092/) {

		$log->info("Not starting MySQL - looks to be user configured.");

		if ($OS ne 'win') {

			my $mysql_config = which('mysql_config');

			# The user might have a socket file in a non-standard
			# location. See bug 3443
			if ($mysql_config && -x $mysql_config) {

				my $socket = `$mysql_config --socket`;
				chomp($socket);

				if ($socket && -S $socket) {
					$class->socketFile($socket);
				}
			}
		}

		return 1;
	}

	for my $dir (Slim::Utils::OSDetect::dirsFor('MySQL')) {

		if (-r catdir($dir, 'my.tt')) {
			$class->mysqlDir($dir);
			last;
		}
	}

	my $cacheDir = $prefs->get('cachedir');

	$class->socketFile( catdir($cacheDir, 'squeezecenter-mysql.sock') ),
	$class->pidFile(    catdir($cacheDir, 'squeezecenter-mysql.pid') );

	$class->confFile( $class->createConfig($cacheDir) );

	if ($class->needSystemTables) {

		$log->info("Creating system tables..");

		$class->createSystemTables;
	}

	# The DB server might already be up.. if it didn't get shutdown last
	# time. That's ok.
	if (!$class->dbh) {

		# Bring MySQL up as a service on Windows.
		if ($OS eq 'win') {

			$class->startServer(1);

		} else {

			$class->startServer;
		}
	}

	return 1;
}

=head2 createConfig( $cacheDir )

Creates a MySQL config file from the L<my.tt> template in the MySQL directory.

=cut

sub createConfig {
	my ($class, $cacheDir) = @_;

	my $ttConf = catdir($class->mysqlDir, 'my.tt');
	my $output = catdir($cacheDir, 'my.cnf');

	my %config = (
		'basedir'  => $class->mysqlDir,
		'language' => $class->mysqlDir,
		'datadir'  => catdir($cacheDir, 'MySQL'),
		'socket'   => $class->socketFile,
		'pidFile'  => $class->pidFile,
		'errorLog' => catdir($cacheDir, 'mysql-error-log.txt'),
		'bindAddress' => $prefs->get('bindAddress'),
	);

	# Because we use the system MySQL, we need to point to the right
	# directory for the errmsg. files. Default to english.
	if (Slim::Utils::OSDetect::isDebian() || Slim::Utils::OSDetect::isRHorSUSE() || Slim::Utils::OSDetect::isGentoo()) {

		$config{'language'} = '/usr/share/mysql/english';
	}

	# If there's no data dir setup - that also means we need to create the system tables.
	if (!-d $config{'datadir'}) {

		mkpath($config{'datadir'});

		$class->needSystemTables(1);
	}

	# Or we've created a data dir, but the system tables didn't get setup..
	if (!-d catdir($config{'datadir'}, 'mysql')) {

		$class->needSystemTables(1);
	}

	# MySQL on Windows wants forward slashes.
	if ($OS eq 'win') {

		for my $key (keys %config) {
			$config{$key} =~ s/\\/\//g;
		}
	}

	$log->info("createConfig() Creating config from file: [$ttConf] -> [$output].");

	my $template = Template->new({ 'ABSOLUTE' => 1 }) or die Template->error(), "\n";
           $template->process($ttConf, \%config, $output) || die $template->error;

	# Bug: 3847 possibly - set permissions on the config file.
	# Breaks all kinds of other things.
	# chmod(0664, $output);

	return $output;
}

=head2 startServer()

Bring up our private copy of MySQL server.

This is a no-op if you are using a pre-configured copy of MySQL.

=cut

sub startServer {
	my $class   = shift;
	my $service = shift || 0;

	my $isRunning = 0;

	if ($service) {

		my %status = ();

		Win32::Service::GetStatus('', $serviceName, \%status);

		if ($status{'CurrentState'} == 0x04) {

			$isRunning = 1;
		}

	} elsif ($class->pidFile && $class->processObj && $class->processObj->alive) {

		$isRunning = 1;
	}

	if ($isRunning) {

		$log->info("MySQL is already running!");

		return 0;
	}

	my $mysqld = Slim::Utils::Misc::findbin('mysqld') || do {

		$log->logdie("FATAL: Couldn't find a executable for 'mysqld'! Exiting.");
	};

	my $confFile = $class->confFile;
	my $process  = undef;

	# Bug: 3461
	if ($OS eq 'win') {
		$mysqld   = Win32::GetShortPathName($mysqld);
		$confFile = Win32::GetShortPathName($confFile);
	}

	my @commands = ($mysqld, sprintf('--defaults-file=%s', $confFile));

	if ( $log->is_info ) {
		$log->info(sprintf("About to start MySQL as a %s with command: [%s]\n",
			($service ? 'service' : 'process'), join(' ', @commands),
		));
	}

	if ($service && $OS eq 'win') {

		my %status = ();

		Win32::Service::GetStatus('', $serviceName, \%status);

		# Attempt to install the service, if it isn't.
		# NB mysqld fails immediately if install is not allowed by user account so don't add this to @commands
		if (scalar keys %status == 0) {

			system( sprintf "%s --install %s %s", $commands[0], $serviceName, $commands[1] );
		}

		Win32::Service::StartService('', $serviceName);

		Win32::Service::GetStatus('', $serviceName, \%status);

		if (scalar keys %status == 0 || ($status{'CurrentState'} != 0x02 && $status{'CurrentState'} != 0x04)) {

			logWarning("Couldn't install MySQL as a service! Will run as a process!");
			$service = 0;
		}
	}

	# Catch Unix users, and Windows users when we couldn't run as a service.
	if (!$service) {

		$process = Proc::Background->new(@commands);
	}

	my $dbh  = undef;
	my $secs = 30;

	# Give MySQL time to get going..
	for (my $i = 0; $i < $secs; $i++) {

		# If we can connect, the server is up.
		if ($dbh = $class->dbh) {
			$dbh->disconnect;
			last;
		}

		sleep 1;
	}

	if ($@) {

		$log->logdie("FATAL: Server didn't startup in $secs seconds! Exiting!");
	}

	$class->processObj($process);

	return 1;
}

=head2 stopServer()

Bring down our private copy of MySQL server.

This is a no-op if you are using a pre-configured copy of MySQL.

Or are running MySQL as a Windows service.

=cut

sub stopServer {
	my $class = shift;
	my $dbh   = shift || $class->dbh;

	if ($OS eq 'win') {

		my %status = ();
		
		Win32::Service::GetStatus('', $serviceName, \%status);

		if (scalar keys %status != 0 && ($status{'CurrentState'} == 0x02 || $status{'CurrentState'} == 0x04)) {

			$log->info("Running service shutdown.");

			if (Win32::Service::StopService('', $serviceName)) {

				return;
			}
			
			$log->warn("Running service shutdown failed!");
		}
	}

	# We have a running server & handle. Shut it down internally.
	if ($dbh) {

		$log->info("Running shutdown.");

		$dbh->func('shutdown', 'admin');
		$dbh->disconnect;

		if ($class->_checkForDeadProcess) {
			return;
		}
	}

	# If the shutdown failed, try to find the pid
	my @pids = ();

	if (ref($class->processObj)) {
		push @pids, $class->processObj->pid;
	}

	if (-f $class->pidFile) {
		chomp(my $pid = read_file($class->pidFile));
		push @pids, $pid;
	}

	for my $pid (@pids) {

		next if !$pid || !kill(0, $pid);

		$log->info("Killing pid: [$pid]");

		kill('TERM', $pid);

		# Wait for the PID file to go away.
		last if $class->_checkForDeadProcess;

		# Try harder.
		kill('KILL', $pid);

		last if $class->_checkForDeadProcess;

		if (kill(0, $pid)) {

			$log->logdie("FATAL: Server didn't shutdown in 20 seconds!");
		}
	}

	# The pid file may be left around..
	unlink($class->pidFile);
}

sub _checkForDeadProcess {
	my $class = shift;

	for (my $i = 0; $i < 10; $i++) {

		if (!-r $class->pidFile) {

			$class->processObj(undef);
			return 1;
		}

		sleep 1;
	}

	return 0;
}

=head2 createSystemTables()

Create required MySQL system tables. See the L<MySQL/system.sql> file.

=cut

sub createSystemTables {
	my $class = shift;

	# We need to bring up MySQL to set the initial system tables, then bring it down again.
	$class->startServer;

	my $sqlFile = catdir($class->mysqlDir, 'system.sql');

	# Connect to the database - doesn't matter what user and no database,
	# in order to setup the system tables. 
	#
	# We need to use the mysql_socket on *nix platforms here, as mysql
	# won't bring up the network port until the tables are installed.
	#
	# On Windows, TCP is the default.

	my $dbh = $class->dbh or do {

		$log->fatal("FATAL: Couldn't connect to database: [$DBI::errstr]");

		$class->stopServer;

		exit;
	};

	if (Slim::Utils::SQLHelper->executeSQLFile('mysql', $dbh, $sqlFile)) {

		$class->createDatabase($dbh);

		# Bring the server down again.
		$class->stopServer($dbh);

		$dbh->disconnect;

		$class->needSystemTables(0);

	} else {

		$log->logdie("FATAL: Couldn't run executeSQLFile on [$sqlFile]! Exiting!");
	}
}

=head2 dbh()

Returns a L<DBI> database handle, using the dbsource preference setting .

=cut

sub dbh {
	my $class = shift;
	my $dsn   = '';

	if ($OS eq 'win') {

		$dsn = $prefs->get('dbsource');
		$dsn =~ s/;database=.+;?//;

	} else {

		$dsn = sprintf('dbi:mysql:mysql_read_default_file=%s', $class->confFile );
	}

	$^W = 0;

	return eval { DBI->connect($dsn, undef, undef, { 'PrintError' => 0, 'RaiseError' => 0 }) };
}

=head2 createDatabase( $dbh )

Creates the initial SqueezeCenter database in MySQL.

'CREATE DATABASE slimserver'

=cut

sub createDatabase {
	my $class  = shift;
	my $dbh    = shift;

	my $source = $prefs->get('dbsource');

	# Set a reasonable default. :)
	my $dbname = 'slimserver';

	if ($source =~ /database=(\w+)/) {
		$dbname = $1;
	}

	eval { $dbh->do("CREATE DATABASE $dbname") };

	if ($@) {

		$log->logdie("FATAL: Couldn't create database with name: [$dbname] - [$DBI::errstr]. Exiting!");
	}
}

=head2 mysqlVersion( $dbh )

Returns the version of MySQL that the $dbh is connected to.

=cut

sub mysqlVersion {
	my $class = shift;
	my $dbh   = shift || return 0;

	my $mysqlVersion = $dbh->get_info($GetInfoType{'SQL_DBMS_VER'}) || 0;

	if ($mysqlVersion && $mysqlVersion =~ /^(\d+\.\d+)/) {

        	return $1;
	}

	return $mysqlVersion || 0;
}

=head2 mysqlVersionLong( $dbh )

Returns the long version string, i.e. 5.0.22-standard

=cut

sub mysqlVersionLong {
	my $class = shift;
	my $dbh   = shift || return 0;

	my ($mysqlVersion) = $dbh->selectrow_array( 'SELECT version()' );

	return $mysqlVersion || 0;
}	

=head2 cleanup()

Shut down MySQL when SqueezeCenter is shut down.

=cut

sub cleanup {
	my $class = shift;

	if ($class->pidFile) {
		$class->stopServer;
	}
}

=head1 SEE ALSO

L<DBI>

L<DBD::mysql>

L<http://www.mysql.com/>

=cut

1;

__END__