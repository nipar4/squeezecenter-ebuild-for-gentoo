package Slim::Utils::OSDetect;

# $Id: OSDetect.pm 21782 2008-07-15 15:39:02Z andy $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

=head1 NAME

Slim::Utils::OSDetect

=head1 DESCRIPTION

L<Slim::Utils::OSDetect> handles Operating System Specific details.

=head1 SYNOPSIS

	for my $baseDir (Slim::Utils::OSDetect::dirsFor('types')) {

		push @typesFiles, catdir($baseDir, 'types.conf');
		push @typesFiles, catdir($baseDir, 'custom-types.conf');
	}
	
	if (Slim::Utils::OSDetect::OS() eq 'win') {

=cut

use strict;
use Config;
use File::Path;
use File::Spec::Functions qw(:ALL);
use FindBin qw($Bin);

BEGIN {

	if ($^O =~ /Win32/) {
		require Win32;
		require Win32::FileSecurity;
		require Win32::TieRegistry;
	}
}

my $detectedOS = undef;
my %osDetails  = ();

=head1 METHODS

=head2 OS( )

returns a string to indicate the detected operating system currently running SqueezeCenter.

=cut

sub OS {
	if (!$detectedOS) { init(); }
	return $detectedOS;
}

=head2 init( $newBin)

 Figures out where the preferences file should be on our platform, and loads it.
 also sets the global $detectedOS to 'unix' 'win', or 'mac'

=cut

sub init {
	my $newBin = shift;

	# Allow the caller to pass in a new base dir (for test cases);
	if (defined $newBin && -d $newBin) {
		$Bin = $newBin;
	}

	if ($detectedOS) {
		return;
	}

	if ($^O =~/darwin/i) {

		$detectedOS = 'mac';

		initDetailsForOSX();

	} elsif ($^O =~ /^m?s?win/i) {

		$detectedOS = 'win';

		initDetailsForWin32();

	} elsif ($^O =~ /linux/i) {

		$detectedOS = 'unix';

		initDetailsForLinux();

	} else {

		$detectedOS = 'unix';

		initDetailsForUnix();
	}
}

=head2 initSearchPath( )

Initialises the binary seach path used by Slim::Utils::Misc::findbin to OS specific locations

=cut

sub initSearchPath {
	# Initialise search path for findbin - called later in initialisation than init above

	# Reduce all the x86 architectures down to i386, including x86_64, so we only need one directory per *nix OS. 
	my $arch = $Config::Config{'archname'};
	$arch =~ s/^(?:i[3456]86|x86_64)-([^-]+).*/i386-$1/;

	my @paths = ( catdir(dirsFor('Bin'), $arch), catdir(dirsFor('Bin'), $^O), dirsFor('Bin') );

	if ($detectedOS eq 'mac') {

		push @paths, $ENV{'HOME'} ."/Library/iTunes/Scripts/iTunes-LAME.app/Contents/Resources/";
	}

	if ($detectedOS ne "win") {

		push @paths, (split(/:/, $ENV{'PATH'}), qw(/usr/bin /usr/local/bin /usr/libexec /sw/bin /usr/sbin));

	} else {

		push @paths, 'C:\Perl\bin';
	}

	$osDetails{'binArch'} = $arch;
	
	Slim::Utils::Misc::addFindBinPaths(@paths);
}

=head2 dirsFor( $dir )

Return OS Specific directories.

Argument $dir is a string to indicate which of the SqueezeCenter directories we
need information for.

=cut

sub dirsFor {
	my $dir     = shift;

	my @dirs    = ();
	my $OS      = OS();
	my $details = details();
	
	# Force OS for SlimService, in case you're testing on a Mac
	if ( main::SLIM_SERVICE ) {
		$OS = 'linux';
	}

	if ($dir eq "Plugins") {
		push @dirs, catdir($Bin, 'Slim', 'Plugin');
	}

	if ($OS eq 'mac') {

		# These are all at the top level.
		if ($dir =~ /^(?:strings|revision|convert|types)$/) {

			push @dirs, $Bin;

		} elsif ($dir =~ /^(?:Graphics|HTML|IR|Plugins|MySQL)$/) {

			# For some reason the dir is lowercase on OS X.
			# FRED: it may have been eons ago but today it is HTML; most of
			# the time anyway OS X is not case sensitive so it does not really
			# matter...
			#if ($dir eq 'HTML') {
			#	$dir = lc($dir);
			#}

			push @dirs, "$ENV{'HOME'}/Library/Application Support/SqueezeCenter/$dir";
			push @dirs, "/Library/Application Support/SqueezeCenter/$dir";
			push @dirs, catdir($Bin, $dir);

		} elsif ($dir eq 'log') {

			push @dirs, catdir($ENV{'HOME'}, '/Library/Logs/SqueezeCenter');

		} elsif ($dir eq 'cache') {

			push @dirs, catdir($ENV{'HOME'}, '/Library/Caches/SqueezeCenter');

		} elsif ($dir eq 'prefs') {

			push @dirs, catdir($ENV{'HOME'}, '/Library/Application Support/SqueezeCenter');

		} elsif ($dir eq 'music') {

			push @dirs, catdir($ENV{'HOME'}, '/Music');

		} elsif ($dir eq 'playlists') {

			push @dirs, catdir($ENV{'HOME'}, '/Music/Playlists');

		} else {

			push @dirs, catdir($Bin, $dir);
		}

	# Debian specific paths.
	} elsif (isDebian()) {

		if ($dir =~ /^(?:Firmware|Graphics|HTML|IR|MySQL|SQL|lib|Bin)$/) {

			push @dirs, "/usr/share/squeezecenter/$dir";

		} elsif ($dir eq 'Plugins') {
			
			push @dirs, "/usr/share/perl5/Slim/Plugin", "/usr/share/squeezecenter/Plugins";
		
		} elsif ($dir eq 'strings' || $dir eq 'revision') {

			push @dirs, "/usr/share/squeezecenter";

		} elsif ($dir =~ /^(?:types|convert)$/) {

			push @dirs, "/etc/squeezecenter";

		} elsif ($dir =~ /^(?:prefs)$/) {

			push @dirs, "/var/lib/squeezecenter/prefs";


		} elsif ($dir eq 'log') {

			push @dirs, "/var/log/squeezecenter";

		} elsif ($dir eq 'cache') {

			push @dirs, "/var/lib/squeezecenter/cache";

		} elsif ($dir eq 'MySQL') {

			# Do nothing - use the depended upon MySQL install.

		} elsif ($dir =~ /^(?:music|playlists)$/) {

			push @dirs, '';

		} else {

			warn "dirsFor: Didn't find a match request: [$dir]\n";
		}

	} elsif (isGentoo()) {

		if ($dir =~ /^(?:Firmware|Graphics|HTML|IR|MySQL|SQL)$/) {

			push @dirs, "/usr/share/squeezecenter/$dir";

		} elsif ($dir =~ /^(?:lib)$/) {

			push @dirs, "/usr/lib/squeezecenter";

		} elsif ($dir eq 'UserPluginRoot') {
			
			push @dirs, "/var/lib/squeezecenter";
		
		} elsif ($dir eq 'Plugins') {
			
			push @dirs, "/var/lib/squeezecenter/Plugins";
			push @dirs, "/usr/lib/" . $Config{'package'} . "/vendor_perl/" . $Config{'version'} . "/Slim/Plugin"
		
		} elsif ($dir eq 'strings' || $dir eq 'revision') {

			push @dirs, "/usr/share/squeezecenter";

		} elsif ($dir =~ /^(?:types|convert)$/) {

			push @dirs, "/etc/squeezecenter";

		} elsif ($dir =~ /^(?:prefs)$/) {

			push @dirs, "/var/lib/squeezecenter/prefs";

		} elsif ($dir eq 'log') {

			push @dirs, "/var/log/squeezecenter";

		} elsif ($dir eq 'cache') {

			push @dirs, "/var/lib/squeezecenter/cache";

		} elsif ($dir eq 'MySQL') {

			# Do nothing - use the depended upon MySQL install.

		} elsif ($dir =~ /^(?:music|playlists)$/) {

			push @dirs, '';

		} else {

			warn "dirsFor: Didn't find a match request: [$dir]\n";
		}

	# Red Hat/Fedora/SUSE RPM specific paths.
	} elsif (isRHorSUSE()) {

		if ($dir =~ /^(?:Firmware|Graphics|HTML|IR|MySQL|SQL|lib|Bin)$/) {

			push @dirs, "/usr/share/squeezecenter/$dir";

		} elsif ($dir eq 'Plugins') {
			
			push @dirs, "/usr/share/squeezecenter/Plugins";
			push @dirs, "/usr/lib/perl5/vendor_perl/Slim/Plugin";
		
		} elsif ($dir eq 'strings' || $dir eq 'revision') {

			push @dirs, "/usr/share/squeezecenter";

		} elsif ($dir =~ /^(?:types|convert)$/) {

			push @dirs, "/etc/squeezecenter";

		} elsif ($dir eq 'prefs') {

			push @dirs, "/var/lib/squeezecenter/prefs";

		} elsif ($dir eq 'log') {

			push @dirs, "/var/log/squeezecenter";

		} elsif ($dir eq 'cache') {

			push @dirs, "/var/lib/squeezecenter/cache";

		} elsif ($dir eq 'MySQL') {

			# Do nothing - use the depended upon MySQL install.

		} elsif ($dir =~ /^(?:music|playlists)$/) {

			push @dirs, '';

		} else {

			warn "dirsFor: Didn't find a match request: [$dir]\n";
		}

	# all Windows specific stuff
	} elsif ($OS eq 'win') {

		if ($dir =~ /^(?:strings|revision|convert|types)$/) {

			push @dirs, $Bin;

		} elsif ($dir eq 'log') {

			push @dirs, winWritablePath('Logs');

		} elsif ($dir eq 'cache') {

			push @dirs, winWritablePath('Cache');

		} elsif ($dir eq 'prefs') {

			push @dirs, winWritablePath('prefs');

		} elsif ($dir =~ /^(?:music|playlists)$/) {

			my $path = '';
			my $swKey = $Win32::TieRegistry::Registry->Open(
				'CUser/Software/Microsoft/Windows/CurrentVersion/Explorer/Shell Folders/', 
				{ 
					Access => Win32::TieRegistry::KEY_READ(), 
					Delimiter =>'/' 
				}
			);

			if (defined $swKey) {
				if (!($path = $swKey->{'My Music'})) {
					if ($path = $swKey->{'Personal'}) {
						$path = $path . '/My Music';
					}
				}
			}

			push @dirs, $path;

		} else {

			push @dirs, catdir($Bin, $dir);
		}

	} elsif ( main::SLIM_SERVICE ) {

		# slimservice on squeezenetwork
		if ( $dir =~ /^(?:strings|revision|convert|types)$/ ) {
			push @dirs, $Bin;
		}
		elsif ( $dir eq 'log' ) {
			if ( $^O eq 'linux' ) {
				push @dirs, '/home/svcprod/ss/logs';
			}
			else {
				push @dirs, catdir( $Bin, $dir );
			}
		}
		elsif ( $dir eq 'cache' ) {
			push @dirs, '/home/svcprod/ss/cache';
		}
		elsif ( $dir eq 'prefs' ) {
			push @dirs, '/home/svcprod/ss/prefs';

		}
		elsif ( $dir =~ /^(?:music|playlists)$/ ) {
			push @dirs, '';
		}
		else {
			push @dirs, catdir( $Bin, $dir );
		}

	} else {

		# Everyone else - *nix.
		if ($dir =~ /^(?:strings|revision|convert|types)$/) {

			push @dirs, $Bin;

		} elsif ($dir eq 'log') {

			push @dirs, catdir($Bin, 'Logs');

		} elsif ($dir eq 'cache') {

			push @dirs, catdir($Bin, 'Cache');

		} elsif ($dir =~ /^(?:music|playlists)$/) {

			push @dirs, '';

		} else {

			push @dirs, catdir($Bin, $dir);
		}
	}

	return wantarray() ? @dirs : $dirs[0];
}

sub details {
	return \%osDetails;
}


=head2 getProxy( )
	Try to read the system's proxy setting by evaluating environment variables,
	registry and browser settings
=cut

sub getProxy {
	my $proxy = '';

	# on Windows read Internet Explorer's proxy setting
	if (Slim::Utils::OSDetect::OS() eq 'win') {
		my $ieSettings = $Win32::TieRegistry::Registry->Open(
			'CUser/Software/Microsoft/Windows/CurrentVersion/Internet Settings',
			{ 
				Access => Win32::TieRegistry::KEY_READ(), 
				Delimiter =>'/' 
			}
		);

		if (defined $ieSettings && hex($ieSettings->{'ProxyEnable'})) {
			$proxy = $ieSettings->{'ProxyServer'};
		}

	}
	
	if (!$proxy) {
		$proxy = $ENV{'http_proxy'};
		my $proxy_port = $ENV{'http_proxy_port'};

		# remove any leading "http://"
		if($proxy) {
			$proxy =~ s/http:\/\///i;
			$proxy = $proxy . ":" .$proxy_port if($proxy_port);
		}
	}

	return $proxy;
}


=head2 isDebian( )

 The Debian package has some specific differences for file locations.
 This routine needs no args, and returns 1 if Debian distro is detected, with
 a clear sign that the .deb package has been installed, 0 if not.

=cut

sub isDebian {

	# Initialize
	my $OS      = OS();
	my $details = details();

	if ($details->{'osName'} eq 'Debian' && $0 =~ m{^/usr/sbin/squeezecenter} ) {
		return 1;
	}

	# ReadyNAS is running a customized Debian
	return isReadyNAS();
}

sub isGentoo {

	# Initialize
	my $OS      = OS();
	my $details = details();

	if ($details->{'osName'} eq 'Gentoo') {
		return 1;
	}

	return 0;
}

sub isRHorSUSE {

	# Initialize
	my $OS      = OS();
	my $details = details();

	if (($details->{'osName'} eq 'Red Hat' || $details->{'osName'} eq 'SUSE') && $0 =~ m{^/usr/libexec/squeezecenter} ) {
		return 1;
	}

	return 0;
}

sub isReadyNAS {

	# Initialize
	my $OS      = OS();
	my $details = details();

	if ($details->{'osName'} eq 'Netgear RAIDiator') {
		return 1;
	}

	return 0;
	
}

sub isVista {

	# Initialize
	my $OS      = OS();
	my $details = details();

	return ($OS eq 'win' && $details->{'osName'} =~ /Vista/) ? 1 : 0;
}

sub initDetailsForWin32 {

	%osDetails = (
		'os'     => 'Windows',

		'osName' => (Win32::GetOSName())[0],

		'osArch' => Win32::GetChipName(),

		'uid'    => Win32::LoginName(),

		'fsType' => (Win32::FsType())[0],
	);

	# Do a little munging for pretty names.
	$osDetails{'osName'} =~ s/Win/Windows /;
	$osDetails{'osName'} =~ s/\/.Net//;
	$osDetails{'osName'} =~ s/2003/Server 2003/;
}

sub initDetailsForOSX {

	# Once for OS Version, then again for CPU Type.
	open(SYS, '/usr/sbin/system_profiler SPSoftwareDataType |') or return;

	while (<SYS>) {

		if (/System Version: (.+)/) {

			$osDetails{'osName'} = $1;
			last;
		}
	}

	close SYS;

	# CPU Type / Processor Name
	open(SYS, '/usr/sbin/system_profiler SPHardwareDataType |') or return;

	while (<SYS>) {

		if (/Intel/i) {

			$osDetails{'osArch'} = 'x86';
			last;

		} elsif (/PowerPC/i) {

			$osDetails{'osArch'} = 'ppc';
		}
	}

	close SYS;

	$osDetails{'os'}  = 'Darwin';
	$osDetails{'uid'} = getpwuid($>);

	for my $dir (
		'Library/Application Support/SqueezeCenter',
		'Library/Application Support/SqueezeCenter/Plugins', 
		'Library/Application Support/SqueezeCenter/Graphics',
		'Library/Application Support/SqueezeCenter/html',
		'Library/Application Support/SqueezeCenter/IR',
		'Library/Logs/SqueezeCenter'
	) {

		eval 'mkpath("$ENV{\'HOME\'}/$dir");';
	}

	unshift @INC, $ENV{'HOME'} . "/Library/Application Support/SqueezeCenter";
	unshift @INC, "/Library/Application Support/SqueezeCenter";
}

sub initDetailsForLinux {

	$osDetails{'os'} = 'Linux';

	if (-f '/etc/raidiator_version') {

		$osDetails{'osName'} = 'Netgear RAIDiator';

	} elsif (-f '/etc/debian_version') {

		$osDetails{'osName'} = 'Debian';

	} elsif (-f '/etc/gentoo-release') {

		$osDetails{'osName'} = 'Gentoo';

	} elsif (-f '/etc/redhat_release' || -f '/etc/redhat-release') {

		$osDetails{'osName'} = 'Red Hat';

	} elsif (-f '/etc/SuSE-release') {

		$osDetails{'osName'} = 'SUSE';

	} else {

		$osDetails{'osName'} = 'Linux';
	}

	$osDetails{'uid'}    = getpwuid($>);
	$osDetails{'osArch'} = $Config{'myarchname'};

	# package specific addition to @INC to cater for plugin locations
	if (isDebian() || isGentoo()) {

		unshift @INC, '/usr/share/squeezecenter';
		unshift @INC, '/usr/share/squeezecenter/CPAN';
	}
}

sub initDetailsForUnix {

	$osDetails{'os'}     = 'Unix';
	$osDetails{'osName'} = $Config{'osname'} || 'Unix';
	$osDetails{'uid'}    = getpwuid($>);
	$osDetails{'osArch'} = $Config{'myarchname'};
}


# Return a path which is expected to be writable by all users on Windows without virtualisation on Vista
# this should mean that the server always sees consistent versions of files under this path

sub winWritablePath {
	my $folder = shift;
	my ($root, $path);

	# use the "Common Application Data" folder to store SqueezeCenter configuration etc.
	# c:\documents and settings\all users\application data - on Windows 2000/XP
	# c:\ProgramData - on Vista
	my $swKey = $Win32::TieRegistry::Registry->Open(
		'LMachine/Software/Microsoft/Windows/CurrentVersion/Explorer/Shell Folders/', 
		{ 
			Access => Win32::TieRegistry::KEY_READ(), 
			Delimiter =>'/' 
		}
	);

	if (defined $swKey && $swKey->{'Common AppData'}) {
		$root = catdir($swKey->{'Common AppData'}, 'SqueezeCenter');
	}
	elsif ($ENV{'ProgramData'}) {
		$root = catdir($ENV{'ProgramData'}, 'SqueezeCenter');
	}
	else {
		$root = $Bin;
	}

	$path = catdir($root, $folder);

	return $path if -d $path;

	if (! -d $root) {
		mkdir $root;
	}

	mkdir $path;

	return $path;
}

# legacy call: this used to do what winWritablePath() does now
# keep it for backwards compatibility
sub vistaWritablePath {
	my $folder = shift;
	Slim::Utils::Log::logger('os.paths')->warn('Slim::Utils::OSDetect::vistaWritablePath() is a legacy call - please use winWritablePath() instead.');
	return winWritablePath($folder);
}

1;

__END__