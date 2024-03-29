#
# Conf.pm: configuration library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2006-2010 Roger Leigh <rleigh@debian.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#######################################################################

package Sbuild::Conf;

use strict;
use warnings;

use Cwd qw(cwd);
use File::Spec;
use POSIX qw(getgroups getgid);
use Sbuild qw(isin);
use Sbuild::ConfBase;
use Sbuild::Sysconfig;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(new setup read);
}

sub setup ($);
sub read ($);

sub new {
    my $conf = Sbuild::ConfBase->new(@_);
    Sbuild::Conf::setup($conf);
    Sbuild::Conf::read($conf);

    return $conf;
}

sub setup ($) {
    my $conf = shift;

    my $validate_program = sub {
	my $conf = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $program = $conf->get($key);

	die "$key binary is not defined"
	    if !defined($program) || !$program;

	# Emulate execvp behaviour by searching the binary in the PATH.
	my @paths = split(/:/, $conf->get('PATH'));
	# Also consider the empty path for absolute locations.
	push (@paths, '');
	my $found = 0;
	foreach my $path (@paths) {
	    $found = 1 if (-x File::Spec->catfile($path, $program));
	}

	die "$key binary '$program' does not exist or is not executable"
	    if !$found;
    };

    my $validate_directory = sub {
	my $conf = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $directory = $conf->get($key);

	die "$key directory is not defined"
	    if !defined($directory) || !$directory;

	die "$key directory '$directory' does not exist"
	    if !-d $directory;
    };

    my $validate_append_version = sub {
	my $conf = shift;
	my $entry = shift;

	if (defined($conf->get('APPEND_TO_VERSION')) &&
	    $conf->get('APPEND_TO_VERSION') &&
	    $conf->get('BUILD_SOURCE') != 0) {
	    # See <http://bugs.debian.org/475777> for details
	    die "The --append-to-version option is incompatible with a source upload\n";
	}

	if ($conf->get('BUILD_SOURCE') &&
	    $conf->get('BIN_NMU')) {
	    print STDERR "Not building source package for binNMU\n";
	    $conf->_set_value('BUILD_SOURCE', 0);
	}
    };

    my $set_signing_option = sub {
	my $conf = shift;
	my $entry = shift;
	my $value = shift;
	my $key = $entry->{'NAME'};
	$conf->_set_value($key, $value);

	my @signing_options = ();
	push @signing_options, "-m".$conf->get('MAINTAINER_NAME')
	    if defined $conf->get('MAINTAINER_NAME');
	push @signing_options, "-e".$conf->get('UPLOADER_NAME')
	    if defined $conf->get('UPLOADER_NAME');
	$conf->set('SIGNING_OPTIONS', \@signing_options);
    };

    our $HOME = $conf->get('HOME');

    my %sbuild_keys = (
	'CHROOT'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'chroot',
	    GROUP => 'Chroot options',
	    DEFAULT => undef,
	    HELP => 'Default chroot (defaults to distribution[-arch][-sbuild])'
	},
	'BUILD_ARCH_ALL'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'build_arch_all',
	    GROUP => 'Build options',
	    DEFAULT => 0,
	    HELP => 'Build architecture: all packages by default'
	},
        'BUILD_ONLY_ARCH_ALL'                   => {
            TYPE => 'BOOL',
            VARNAME => 'build_only_arch_all',
            GROUP => 'Build options',
            DEFAULT => 0,
            HELP => 'Build architecture: only all packages'
        },
	'BUILD_ARCH_ANY'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'build_arch_any',
	    GROUP => 'Build options',
	    DEFAULT => 1,
	    HELP => 'Build architecture: any packages by default'
	},
	'NOLOG'					=> {
	    TYPE => 'BOOL',
	    GROUP => '__INTERNAL',
	    DEFAULT => 0,
	    HELP => 'Disable use of log file'
	},
	'SUDO'					=> {
	    TYPE => 'STRING',
	    VARNAME => 'sudo',
	    GROUP => 'Programs',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('CHROOT_MODE') eq 'split' ||
		    ($conf->get('CHROOT_MODE') eq 'schroot' &&
		     $conf->get('CHROOT_SPLIT'))) {
		    $validate_program->($conf, $entry);

		    local (%ENV) = %ENV; # make local environment
		    $ENV{'DEBIAN_FRONTEND'} = "noninteractive";
		    $ENV{'APT_CONFIG'} = "test_apt_config";
		    $ENV{'SHELL'} = '/bin/sh';

		    my $sudo = $conf->get('SUDO');
		    chomp( my $test_df = `$sudo sh -c 'echo \$DEBIAN_FRONTEND'` );
		    chomp( my $test_ac = `$sudo sh -c 'echo \$APT_CONFIG'` );
		    chomp( my $test_sh = `$sudo sh -c 'echo \$SHELL'` );

		    if ($test_df ne "noninteractive" ||
			$test_ac ne "test_apt_config" ||
			$test_sh ne '/bin/sh') {
			print STDERR "$sudo is stripping APT_CONFIG, DEBIAN_FRONTEND and/or SHELL from the environment\n";
			print STDERR "'Defaults:" . $conf->get('USERNAME') . " env_keep+=\"APT_CONFIG DEBIAN_FRONTEND SHELL\"' is not set in /etc/sudoers\n";
			die "$sudo is incorrectly configured"
		    }
		}
	    },
	    DEFAULT => 'sudo',
	    HELP => 'Path to sudo binary'
	},
	'SU'					=> {
	    TYPE => 'STRING',
	    VARNAME => 'su',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'su',
	    HELP => 'Path to su binary'
	},
	'SCHROOT'				=> {
	    TYPE => 'STRING',
	    GROUP => '__INTERNAL',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('CHROOT_MODE') eq 'schroot') {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'schroot',
	    HELP => 'Path to schroot binary'
	},
	'SCHROOT_OPTIONS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'schroot_options',
	    GROUP => 'Programs',
	    DEFAULT => ['-q'],
	    HELP => 'Additional command-line options for schroot'
	},
	'FAKEROOT'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'fakeroot',
	    GROUP => 'Programs',
	    DEFAULT => 'fakeroot',
	    HELP => 'Path to fakeroot binary'
	},
	'APT_GET'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'apt_get',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'apt-get',
	    HELP => 'Path to apt-get binary'
	},
	'APT_CACHE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'apt_cache',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'apt-cache',
	    HELP => 'Path to apt-cache binary'
	},
	'APTITUDE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'aptitude',
	    GROUP => 'Programs',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('BUILD_DEP_RESOLVER') eq 'aptitude') {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'aptitude',
	    HELP => 'Path to aptitude binary'
	},
	'XAPT'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'xapt',
	    GROUP => 'Programs',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('BUILD_DEP_RESOLVER') eq 'xapt') {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'xapt'
	},
	'DPKG_BUILDPACKAGE_USER_OPTIONS'	=> {
	    TYPE => 'ARRAY:STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => [],
	    HELP => 'Additional command-line options for dpkg-buildpackage.  Not settable in config.'
	},
	'DPKG_SOURCE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'dpkg_source',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'dpkg-source',
	    HELP => 'Path to dpkg-source binary'
	},
	'DPKG_SOURCE_OPTIONS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'dpkg_source_opts',
	    GROUP => 'Programs',
	    DEFAULT => [],
	    HELP => 'Additional command-line options for dpkg-source'
	},
	'DCMD'					=> {
	    TYPE => 'STRING',
	    VARNAME => 'dcmd',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'dcmd',
	    HELP => 'Path to dcmd binary'
	},
	'MD5SUM'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'md5sum',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'md5sum',
	    HELP => 'Path to md5sum binary'
	},
	'STATS_DIR'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'stats_dir',
	    GROUP => 'Statistics',
	    DEFAULT => "$HOME/stats",
	    HELP => 'Directory for writing build statistics to'
	},
	'PACKAGE_CHECKLIST'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'package_checklist',
	    GROUP => 'Chroot options',
	    DEFAULT => "$Sbuild::Sysconfig::paths{'SBUILD_LOCALSTATE_DIR'}/package-checklist",
	    HELP => 'Where to store list currently installed packages inside chroot'
	},
	'BUILD_ENV_CMND'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'build_env_cmnd',
	    GROUP => 'Build options',
	    DEFAULT => "",
	    HELP => 'This command is run with the dpkg-buildpackage command line passed to it (in the chroot, if doing a chrooted build).  It is used by the sparc buildd (which is sparc64) to call the wrapper script that sets the environment to sparc (32-bit).  It could be used for other build environment setup scripts.  Note that this is superceded by schroot\'s \'command-prefix\' option'
	},
	'PGP_OPTIONS'				=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'pgp_options',
	    GROUP => 'Build options',
	    DEFAULT => ['-us', '-uc'],
	    HELP => 'Additional signing options for dpkg-buildpackage'
	},
	'LOG_DIR'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'log_dir',
	    GROUP => 'Logging options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};
		my $directory = $conf->get($key);
	    },
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		# user mode defaults to the build directory, while buildd mode
		# defaults to $HOME/logs.
		if (!defined($retval)) {
		    $retval = $conf->get('BUILD_DIR');
		    if ($conf->get('SBUILD_MODE') eq 'buildd') {
			$retval = "$HOME/logs";
		    }
		}

		return $retval;
	    },
	    HELP => 'Directory for storing build logs.  This defaults to \'.\' when SBUILD_MODE is set to \'user\' (the default), and to \'$HOME/logs\' when SBUILD_MODE is set to \'buildd\'.'
	},
	'LOG_COLOUR'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'log_colour',
	    GROUP => 'Logging options',
	    DEFAULT => 1,
	    HELP => 'Add colour highlighting to interactive log messages (informational, warning and error messages).  Log files will not be coloured.'
	},
	'LOG_FILTER'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'log_filter',
	    GROUP => 'Logging options',
	    DEFAULT => 1,
	    HELP => 'Filter variable strings from log messages such as the chroot name and build directory'
	},
	'LOG_COLOUR'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'log_colour',
	    GROUP => 'Logging options',
	    DEFAULT => 1,
	    HELP => 'Colour log messages such as critical failures, warnings and success'
	},
	'LOG_DIR_AVAILABLE'			=> {
	    TYPE => 'BOOL',
	    GROUP => '__INTERNAL',
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $nolog = $conf->get('NOLOG');
		my $directory = $conf->get('LOG_DIR');
		my $log_dir_available = 1;

		if ($nolog) {
			$log_dir_available = 0;
		} elsif ($conf->get('SBUILD_MODE') ne "buildd") {
		    if ($directory && ! -d $directory) {
			$log_dir_available = 0;
		    }
		} elsif ($directory && ! -d $directory &&
			 !mkdir $directory) {
		    # Only create the log dir in buildd mode
		    warn "Could not create '$directory': $!\n";
		    $log_dir_available = 0;
		}

		return $log_dir_available;
	    }
	},
	'MAILTO'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'mailto',
	    GROUP => 'Logging options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "mailto not set\n"
		    if !$conf->get('MAILTO') &&
		    $conf->get('SBUILD_MODE') eq "buildd";
	    },
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		# Now, we might need to adjust the MAILTO based on the
		# config data. We shouldn't do this if it was already
		# explicitly set by the command line option:
		if (defined($conf->get('MAILTO_FORCED_BY_CLI')) &&
		    !$conf->get('MAILTO_FORCED_BY_CLI')
		    && defined($conf->get('DISTRIBUTION'))
		    && $conf->get('DISTRIBUTION')
		    && defined($conf->get('MAILTO_HASH'))
		    && $conf->get('MAILTO_HASH')->{$conf->get('DISTRIBUTION')}) {
		    $retval = $conf->get('MAILTO_HASH')->{$conf->get('DISTRIBUTION')};
		}

		return $retval;
	    },
	    DEFAULT => "",
	    HELP => 'email address to mail build logs to'
	},
	'MAILTO_FORCED_BY_CLI'			=> {
	    TYPE => 'BOOL',
	    GROUP => '__INTERNAL',
	    DEFAULT => 0
	},
	'MAILTO_HASH'				=> {
	    TYPE => 'HASH:STRING',
	    VARNAME => 'mailto_hash',
	    GROUP => 'Logging options',
	    DEFAULT => {},
	    HELP => 'Like MAILTO, but per-distribution.  This is a hashref mapping distribution name to MAILTO.  Note that for backward compatibility, this is also settable using the hash %mailto (deprecated), rather than a hash reference.'
	},
	'MAILFROM'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'mailfrom',
	    GROUP => 'Logging options',
	    DEFAULT => "Source Builder <sbuild>",
	    HELP => 'email address set in the From line of build logs'
	},
	'COMPRESS_BUILD_LOG_MAILS'              => {
	    TYPE => 'BOOL',
	    VARNAME => 'compress_build_log_mails',
	    GROUP => 'Logging options',
	    DEFAULT => 1,
	    HELP => 'Should build log mails be compressed?'
	},
	'MIME_BUILD_LOG_MAILS'                  => {
	    TYPE => 'BOOL',
	    VARNAME => 'mime_build_log_mails',
	    GROUP => 'Logging options',
	    DEFAULT => 1,
	    HELP => 'Should build log mails be MIME encoded?'
	},
	'PURGE_BUILD_DEPS'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'purge_build_deps',
	    GROUP => 'Chroot options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $conf->get('PURGE_BUILD_DEPS') . "\'"
		    if !isin($conf->get('PURGE_BUILD_DEPS'),
			     qw(always successful never));
	    },
	    DEFAULT => 'always',
	    HELP => 'When to purge the build dependencies after a build; possible values are "never", "successful", and "always"'
	},
	'PURGE_BUILD_DIRECTORY'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'purge_build_directory',
	    GROUP => 'Chroot options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $conf->get('PURGE_BUILD_DIRECTORY') . "\'"
		    if !isin($conf->get('PURGE_BUILD_DIRECTORY'),
			     qw(always successful never));
	    },
	    DEFAULT => 'always',
	    HELP => 'When to purge the build directory after a build; possible values are "never", "successful", and "always"'
	},
	'PURGE_SESSION'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'purge_session',
	    GROUP => 'Chroot options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $conf->get('PURGE_SESSION') . "\'"
		    if !isin($conf->get('PURGE_SESSION'),
			     qw(always successful never));
	    },
	    DEFAULT => 'always',
	    HELP => 'Purge the schroot session following a build.  This is useful in conjunction with the --purge and --purge-deps options when using snapshot chroots, since by default the snapshot will be deleted. Possible values are "always" (default), "never", and "successful"'
	},
	'TOOLCHAIN_REGEX'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'toolchain_regex',
	    GROUP => 'Build options',
	    DEFAULT => ['binutils$',
			'dpkg-dev$',
			'gcc-[\d.]+$',
			'g\+\+-[\d.]+$',
			'libstdc\+\+',
			'libc[\d.]+-dev$',
			'linux-kernel-headers$',
			'linux-libc-dev$',
			'gnumach-dev$',
			'hurd-dev$',
			'kfreebsd-kernel-headers$'
		],
	    HELP => 'Regular expressions identifying toolchain packages.  Note that for backward compatibility, this is also settable using the array @toolchain_regex (deprecated), rather than an array reference.'
	},
	'STALLED_PKG_TIMEOUT'			=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'stalled_pkg_timeout',
	    GROUP => 'Build timeouts',
	    DEFAULT => 150, # minutes
	    HELP => 'Time (in minutes) of inactivity after which a build is terminated. Activity is measured by output to the log file.'
	},
	'MAX_LOCK_TRYS'				=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'max_lock_trys',
	    GROUP => 'Build timeouts',
	    DEFAULT => 120,
	    HELP => 'Number of times to try waiting for a lock.'
	},
	'LOCK_INTERVAL'				=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'lock_interval',
	    GROUP => 'Build timeouts',
	    DEFAULT => 5,
	    HELP => 'Lock wait interval (seconds).  Maximum wait time is (max_lock_trys × lock_interval).'
	},
	'CHROOT_MODE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'chroot_mode',
	    GROUP => 'Chroot options',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad chroot mode \'" . $conf->get('CHROOT_MODE') . "\'"
		    if !isin($conf->get('CHROOT_MODE'),
			     qw(schroot sudo));
	    },
	    DEFAULT => 'schroot',
	    HELP => 'Mechanism to use for chroot virtualisation.  Possible value are "schroot" (default) and "sudo".'
	},
	'CHROOT_SPLIT'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'chroot_split',
	    GROUP => 'Chroot options',
	    DEFAULT => 0,
	    HELP => 'Run in split mode?  In split mode, apt-get and dpkg are run on the host system, rather than inside the chroot.'
	},
	'CHECK_SPACE'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'check_space',
	    GROUP => 'Build options',
	    DEFAULT => 1,
	    HELP => 'Check free disk space prior to starting a build.  sbuild requires the free space to be at least twice the size of the unpacked sources to allow a build to proceed.  Can be disabled to allow building if space is very limited, but the threshold to abort a build has been exceeded despite there being sufficient space for the build to complete.'
	},
	'BUILD_DIR'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'build_dir',
	    GROUP => 'Core options',
	    DEFAULT => cwd(),
	    IGNORE_DEFAULT => 1, # Don't dump class to config
	    EXAMPLE => '$build_dir = \'/home/pete/build\';',
	    CHECK => $validate_directory,
	    HELP => 'This option is deprecated.  Directory for chroot symlinks and sbuild logs.  Defaults to the current directory if unspecified.  It is used as the location of chroot symlinks (obsolete) and for current build log symlinks and some build logs.  There is no default; if unset, it defaults to the current working directory.  $HOME/build is another common configuration.'
	},
	'SBUILD_MODE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'sbuild_mode',
	    GROUP => 'Core options',
	    DEFAULT => 'user',
	    HELP => 'sbuild behaviour; possible values are "user" (exit status reports build failures) and "buildd" (exit status does not report build failures) for use in a buildd setup.  "buildd" also currently implies enabling of "legacy features" such as chroot symlinks in the build directory and the creation of current symlinks in the build directory.'
	},
	'CHROOT_SETUP_SCRIPT'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'chroot_setup_script',
	    GROUP => 'Chroot options',
	    DEFAULT => undef,
	    HELP => 'Script to run to perform custom setup tasks in the chroot.'
	},
	'FORCE_ORIG_SOURCE'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'force_orig_source',
	    GROUP => 'Build options',
	    DEFAULT => 0,
	    HELP => 'By default, the -s option only includes the .orig.tar.gz when needed (i.e. when the Debian revision is 0 or 1).  By setting this option to 1, the .orig.tar.gz will always be included when -s is used.  This is equivalent to --force-orig-source.'
	},
	'INDIVIDUAL_STALLED_PKG_TIMEOUT'	=> {
	    TYPE => 'HASH:NUMERIC',
	    VARNAME => 'individual_stalled_pkg_timeout',
	    GROUP => 'Build timeouts',
	    DEFAULT => {},
	    HELP => 'Some packages may exceed the general timeout (e.g. redirecting output to a file) and need a different timeout.  This has is a mapping between source package name and timeout.  Note that for backward compatibility, this is also settable using the hash %individual_stalled_pkg_timeout (deprecated) , rather than a hash reference.',
	    EXAMPLE =>
'%individual_stalled_pkg_timeout = (smalleiffel => 300,
				   jade => 300,
				   atlas => 300,
				   glibc => 1000,
				   \'gcc-3.3\' => 300,
				   kwave => 600);'
	},
	'ENVIRONMENT_FILTER'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'environment_filter',
	    GROUP => 'Core options',
	    DEFAULT => ['^PATH$',
			'^DEB(IAN|SIGN)?_[A-Z_]+$',
	    		'^(C(PP|XX)?|LD|F)FLAGS(_APPEND)?$',
			'^USER(NAME)?$',
			'^LOGNAME$',
			'^HOME$',
			'^TERM$',
			'^SHELL$'],
	    HELP => 'Only environment variables matching one of the regular expressions in this arrayref will be passed to dpkg-buildpackage and other programs run by sbuild.'
	},
	'BUILD_ENVIRONMENT'			=> {
	    TYPE => 'HASH:STRING',
	    VARNAME => 'build_environment',
	    GROUP => 'Core options',
	    DEFAULT => {},
	    HELP => 'Environment to set during the build.  Defaults to setting PATH and LD_LIBRARY_PATH only.  Note that these environment variables are not subject to filtering with ENVIRONMENT_FILTER.  Example:',
	    EXAMPLE =>
'$build_environment = {
        \'CCACHE_DIR\' => \'/build/cache\'
};'
	},
	'LD_LIBRARY_PATH'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'ld_library_path',
	    GROUP => 'Build environment',
	    DEFAULT => undef,
	    HELP => 'Library search path to use inside the chroot.'
	},
	'MAINTAINER_NAME'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'maintainer_name',
	    GROUP => 'Maintainer options',
	    DEFAULT => undef,
	    SET => $set_signing_option,
	    HELP => 'Name to use as override in .changes files for the Maintainer field.  The Maintainer field will not be overridden unless set here.'
	},
	'UPLOADER_NAME'				=> {
	    VARNAME => 'uploader_name',
	    TYPE => 'STRING',
	    GROUP => 'Maintainer options',
	    DEFAULT => undef,
	    SET => $set_signing_option,
	    HELP => 'Name to use as override in .changes file for the Changed-By: field.'
	},
	'KEY_ID'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'key_id',
	    GROUP => 'Maintainer options',
	    DEFAULT => undef,
	    HELP => 'Key ID to use in .changes for the current upload.  It overrides both $maintainer_name and $uploader_name.'
	},
	'SIGNING_OPTIONS'			=> {
	    TYPE => 'STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => "",
	    HELP => 'PGP-related identity options to pass to dpkg-buildpackage. Usually neither .dsc nor .changes files are not signed automatically.'
	},
	'APT_CLEAN'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_clean',
	    GROUP => 'Chroot options',
	    DEFAULT => 0,
	    HELP => 'APT clean.  1 to enable running "apt-get clean" at the start of each build, or 0 to disable.'
	},
	'APT_UPDATE'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_update',
	    GROUP => 'Chroot options',
	    DEFAULT => 1,
	    HELP => 'APT update.  1 to enable running "apt-get update" at the start of each build, or 0 to disable.'
	},
	'APT_UPDATE_ARCHIVE_ONLY'		=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_update_archive_only',
	    GROUP => 'Chroot options',
	    DEFAULT => 1,
	    HELP => 'Update local temporary APT archive directly (1, the default) or set to 0 to disable and do a full apt update (not recommended in case the mirror content has changed since the build started).'
	},
	'APT_UPGRADE'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_upgrade',
	    GROUP => 'Chroot options',
	    DEFAULT => 0,
	    HELP => 'APT upgrade.  1 to enable running "apt-get upgrade" at the start of each build, or 0 to disable.'
	},
	'APT_DISTUPGRADE'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_distupgrade',
	    GROUP => 'Chroot options',
	    DEFAULT => 1,
	    HELP => 'APT distupgrade.  1 to enable running "apt-get dist-upgrade" at the start of each build, or 0 to disable.'
	},
	'APT_ALLOW_UNAUTHENTICATED'		=> {
	    TYPE => 'BOOL',
	    VARNAME => 'apt_allow_unauthenticated',
	    GROUP => 'Chroot options',
	    DEFAULT => 0,
	    HELP => 'Force APT to accept unauthenticated packages.  By default, unauthenticated packages are not allowed.  This is to keep the build environment secure, using apt-secure(8).  By setting this to 1, APT::Get::AllowUnauthenticated is set to "true" when running apt-get. This is disabled by default: only enable it if you know what you are doing.'
	},
	'BATCH_MODE'				=> {
	    TYPE => 'BOOL',
	    GROUP => '__INTERNAL',
	    DEFAULT => 0,
	    HELP => 'Enable batch mode?'
	},
	'CORE_DEPENDS'				=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'core_depends',
	    GROUP => 'Core options',
	    DEFAULT => ['build-essential', 'fakeroot'],
	    HELP => 'Packages which must be installed in the chroot for all builds.'
	},
	'MANUAL_DEPENDS'			=> {
	    TYPE => 'ARRAY:STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.  Do not set by hand.'
	},
	'MANUAL_CONFLICTS'			=> {
	    TYPE => 'ARRAY:STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.  Do not set by hand.'
	},
	'MANUAL_DEPENDS_ARCH'			=> {
	    TYPE => 'ARRAY:STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.  Do not set by hand.'
	},
	'MANUAL_CONFLICTS_ARCH'			=> {
	    TYPE => 'ARRAY:STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.  Do not set by hand.'
	},
	'MANUAL_DEPENDS_INDEP'			=> {
	    TYPE => 'ARRAY:STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.  Do not set by hand.'
	},
	'MANUAL_CONFLICTS_INDEP'		=> {
	    TYPE => 'ARRAY:STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.  Do not set by hand.'
	},
	'CROSSBUILD_CORE_DEPENDS'				=> {
	    TYPE => 'HASH:ARRAY:STRING',
	    VARNAME => 'crossbuild_core_depends',
	    GROUP => 'Multiarch support (transitional)',
	    DEFAULT => { arm64 => ['crossbuild-essential-arm64'],
			 armel => ['crossbuild-essential-armel'],
			 armhf => ['crossbuild-essential-armhf'],
			 ia64 => ['crossbuild-essential-ia64'],
			 mips => ['crossbuild-essential-mips'],
			 mipsel => ['crossbuild-essential-mipsel'],
			 powerpc => ['crossbuild-essential-powerpc'],
			 sparc => ['crossbuild-essential-sparc']
	    	       },
	    HELP => 'Per-architecture dependencies required for cross-building.'
	},	'BUILD_SOURCE'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'build_source',
	    GROUP => 'Build options',
	    DEFAULT => 0,
	    CHECK => $validate_append_version,
	    HELP => 'By default, do not build a source package (binary only build).  Set to 1 to force creation of a source package, but note that this is inappropriate for binary NMUs, where the option will always be disabled.'
	},
	'ARCHIVE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'archive',
	    GROUP => 'Core options',
	    DEFAULT => undef,
	    HELP => 'Archive being built.  Only set in build log.  This might be useful for derivative distributions.'
	},
	'BIN_NMU'				=> {
	    TYPE => 'STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => undef,
	    CHECK => $validate_append_version,
	    HELP => 'Binary NMU changelog entry.  Do not set by hand.'
	},
	'BIN_NMU_VERSION'			=> {
	    TYPE => 'STRING',
	    GROUP => '__INTERNAL',
	    DEFAULT => undef,
	    HELP => 'Binary NMU version number.  Do not set by hand.'
	},
	'APPEND_TO_VERSION'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'append_to_version',
	    GROUP => 'Build options',
	    DEFAULT => undef,
	    CHECK => $validate_append_version,
	    HELP => 'Suffix to append to version number.  May be useful for derivative distributions.'
	},
	'GCC_SNAPSHOT'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'gcc_snapshot',
	    GROUP => 'Build options',
	    DEFAULT => 0,
	    HELP => 'Build using current GCC snapshot?'
	},
	'JOB_FILE'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'job_file',
	    GROUP => 'Core options',
	    DEFAULT => 'build-progress',
	    HELP => 'Job status file (only used in batch mode)'
	},
	'BUILD_DEP_RESOLVER'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'build_dep_resolver',
	    GROUP => 'Dependency resolution',
	    DEFAULT => 'apt',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		if ($conf->get($key) eq 'internal') {
		    warn "W: Build dependency resolver 'internal' has been removed; defaulting to 'apt'.  Please update your configuration.\n";
		    $conf->set('BUILD_DEP_RESOLVER', 'apt');
		}

		die '$key: Invalid build-dependency resolver \'' .
		    $conf->get($key) .
		    "'\nValid algorithms are 'apt', 'aptitude' and 'xapt'\n"
		    if !isin($conf->get($key),
			     qw(apt aptitude xapt));
	    },
	    HELP => 'Build dependency resolver.  The \'apt\' resolver is currently the default, and recommended for most users.  This resolver uses apt-get to resolve dependencies.  Alternative resolvers are \'apt\' and \'aptitude\', which use a built-in resolver module and aptitude to resolve build dependencies, respectively.  The aptitude resolver is similar to apt, but is useful in more complex situations, such as where multiple distributions are required, for example when building from experimental, where packages are needed from both unstable and experimental, but defaulting to unstable.'
	},
	'LINTIAN'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'lintian',
	    GROUP => 'Build validation',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('RUN_LINTIAN')) {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'lintian',
	    HELP => 'Path to lintian binary'
	},
	'RUN_LINTIAN'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'run_lintian',
	    GROUP => 'Build validation',
	    CHECK => sub {
		my $conf = shift;
		$conf->check('LINTIAN');
	    },
	    DEFAULT => 0,
	    HELP => 'Run lintian?'
	},
	'LINTIAN_OPTIONS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'lintian_opts',
	    GROUP => 'Build validation',
	    DEFAULT => [],
	    HELP => 'Options to pass to lintian.  Each option is a separate arrayref element.  For example, [\'-i\', \'-v\'] to add -i and -v.'
	},
	'PIUPARTS'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'piuparts',
	    GROUP => 'Build validation',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('RUN_PIUPARTS')) {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'piuparts',
	    HELP => 'Path to piuparts binary'
	},
	'RUN_PIUPARTS'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'run_piuparts',
	    GROUP => 'Build validation',
	    CHECK => sub {
		my $conf = shift;
		$conf->check('PIUPARTS');
	    },
	    DEFAULT => 0,
	    HELP => 'Run piuparts'
	},
	'PIUPARTS_OPTIONS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'piuparts_opts',
	    GROUP => 'Build validation',
	    DEFAULT => [],
	    HELP => 'Options to pass to piuparts.  Each option is a separate arrayref element.  For example, [\'-b\', \'<chroot_tarball>\'] to add -b and <chroot_tarball>.'
	},
	'PIUPARTS_ROOT_ARGS'			=> {
	    TYPE => 'ARRAY:STRING',
	    VARNAME => 'piuparts_root_args',
	    GROUP => 'Build validation',
	    DEFAULT => [],
	    HELP => 'Preceding arguments to launch piuparts as root. If no arguments are specified, piuparts will be launched via sudo.'
	},
	'EXTERNAL_COMMANDS'			=> {
	    TYPE => 'HASH:ARRAY:ARRAY:STRING',
	    VARNAME => 'external_commands',
	    GROUP => 'Chroot options',
	    DEFAULT => {
		"pre-build-commands" => [],
		"chroot-setup-commands" => [],
		"chroot-cleanup-commands" => [],
		"post-build-commands" => [],
	    },
	    HELP => 'External commands to run at various stages of a build. Commands are held in a hash of arrays of arrays data structure.',
	    EXAMPLE =>
'$external_commands = {
    "pre-build-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "chroot-setup-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "chroot-cleanup-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "post-build-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
};'
	},
	'LOG_EXTERNAL_COMMAND_OUTPUT'		=> {
	    TYPE => 'BOOL',
	    VARNAME => 'log_external_command_output',
	    GROUP => 'Chroot options',
	    DEFAULT => 1,
	    HELP => 'Log standard output of commands run by sbuild?'
	},
	'LOG_EXTERNAL_COMMAND_ERROR'		=> {
	    TYPE => 'BOOL',
	    VARNAME => 'log_external_command_error',
	    GROUP => 'Chroot options',
	    DEFAULT => 1,
	    HELP => 'Log standard error of commands run by sbuild?'
	},
	'RESOLVE_ALTERNATIVES'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'resolve_alternatives',
	    GROUP => 'Dependency resolution',
	    DEFAULT => undef,
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get($entry->{'NAME'});

		if (!defined($retval)) {
		    $retval = 0;
		    $retval = 1
			if ($conf->get('BUILD_DEP_RESOLVER') eq 'aptitude');
		}

		return $retval;
	    },
	    EXAMPLE => '$resolve_alternatives = 0;',
	    HELP => 'Should the dependency resolver use alternatives in Build-Depends, Build-Depends-Arch and Build-Depends-Indep?  By default, using \'apt\' resolver, only the first alternative will be used; all other alternatives will be removed.  When using the \'aptitude\' resolver, it will default to using all alternatives.  Note that this does not include architecture-specific alternatives, which are reduced to the build architecture prior to alternatives removal.  This should be left disabled when building for unstable; it may be useful when building for experimental or backports.  Set to undef to use the default, 1 to enable, or 0 to disable.'
	},
	'SBUILD_BUILD_DEPENDS_SECRET_KEY'		=> {
	    TYPE => 'STRING',
	    VARNAME => 'sbuild_build_depends_secret_key',
	    GROUP => 'Dependency resolution',
	    DEFAULT => '/var/lib/sbuild/apt-keys/sbuild-key.sec',
	    HELP => 'GPG secret key for temporary local apt archive.'
	},
	'SBUILD_BUILD_DEPENDS_PUBLIC_KEY'		=> {
	    TYPE => 'STRING',
	    VARNAME => 'sbuild_build_depends_public_key',
	    GROUP => 'Dependency resolution',
	    DEFAULT => '/var/lib/sbuild/apt-keys/sbuild-key.pub',
	    HELP => 'GPG public key for temporary local apt archive.'
	},
    );

    $conf->set_allowed_keys(\%sbuild_keys);
}

sub read ($) {
    my $conf = shift;

    # Set here to allow user to override.
    if (-t STDIN && -t STDOUT) {
	$conf->_set_default('VERBOSE', 1);
    } else {
	$conf->_set_default('VERBOSE', 0);
    }

    my $HOME = $conf->get('HOME');

    my $files = ["$Sbuild::Sysconfig::paths{'SBUILD_CONF'}",
		 "$HOME/.sbuildrc"];

    # For compatibility only.  Non-scalars are deprecated.
    my $deprecated_init = <<END;
my \%mailto;
undef \%mailto;
my \@toolchain_regex;
undef \@toolchain_regex;
my \%individual_stalled_pkg_timeout;
undef \%individual_stalled_pkg_timeout;
END

    my $deprecated_setup = <<END;
# Non-scalar values, for backward compatibility.
if (\%mailto) {
    warn 'W: \%mailto is deprecated; please use the hash reference \$mailto{}\n';
    \$conf->set('MAILTO_HASH', \\\%mailto);
}
if (\@toolchain_regex) {
    warn 'W: \@toolchain_regex is deprecated; please use the array reference \$toolchain_regexp[]\n';
    \$conf->set('TOOLCHAIN_REGEX', \\\@toolchain_regex);
}
if (\%individual_stalled_pkg_timeout) {
    warn 'W: \%individual_stalled_pkg_timeout is deprecated; please use the hash reference \$individual_stalled_pkg_timeout{}\n';
    \$conf->set('INDIVIDUAL_STALLED_PKG_TIMEOUT',
		\\\%individual_stalled_pkg_timeout);
}
END

    my $custom_setup = <<END;
push(\@{\${\$conf->get('EXTERNAL_COMMANDS')}{"chroot-setup-commands"}},
\$chroot_setup_script) if (\$chroot_setup_script);

    # Trigger log directory creation if needed
    \$conf->get('LOG_DIR_AVAILABLE');

END


    $conf->read($files, $deprecated_init, $deprecated_setup,
		$custom_setup);
}

1;
