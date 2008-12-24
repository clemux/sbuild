#
# Options.pm: options parser for wanna-build
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org>
# Copyright © 2008      Simon McVittie <smcv@debian.org>
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

package WannaBuild::Options;

use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case auto_abbrev gnu_getopt);
use Sbuild qw(help_text version_text usage_error);
use Sbuild::Base;
use Sbuild::DBInfo;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    if (!$self->parse_options()) {
	usage_error("wanna-build", "Error parsing command-line options");
	return undef;
    }
    return $self;
}

sub parse_options {
    my $self = shift;

    return GetOptions (
	"h|help" => sub { help_text("1", "wanna-build"); },
	"V|version" => sub {version_text("wanna-build"); },
	"v|verbose" => sub {
	    $self->set_conf('VERBOSE',
			    $self->get_conf('VERBOSE') + 1);
	},
	"d|dist=s" => sub {
	    $self->set_conf('DISTRIBUTION', $_[1]);
	    $self->set_conf('DISTRIBUTION', "oldstable")
		if $self->get_conf('DISTRIBUTION') eq "o";
	    $self->set_conf('DISTRIBUTION', "stable")
		if $self->get_conf('DISTRIBUTION') eq "s";
	    $self->set_conf('DISTRIBUTION', "testing")
		if $self->get_conf('DISTRIBUTION') eq "t";
	    $self->set_conf('DISTRIBUTION', "unstable")
		if $self->get_conf('DISTRIBUTION') eq "u";
	    $self->set_conf('DISTRIBUTION', "experimental")
		if $self->get_conf('DISTRIBUTION') eq "e";
	    $self->set_conf('OVERRIDE_DISTRIBUTION', 1);

	    # TODO: Get entire list from database, and
	    # remove DB_INFO_ALL_DISTS.
	    if ($self->get_conf('DISTRIBUTION') eq "a" ||
		$self->get_conf('DISTRIBUTION') eq "all") {
		$self->set_conf('DB_INFO_ALL_DISTS', 1);
		$self->set_conf('DISTRIBUTION', "")
	    }
	},

	"o|override" => sub {
	    $self->set_conf('DB_OVERRIDE', 1); # <- $opt_override
	},
	"create-db" => sub {
	    $self->set_conf('DB_CREATE', 1); # <- $opt_create_db
	},
	# TODO: Remove opt_ prefix...
	"correct-compare" => \$Sbuild::opt_correct_version_cmp,
	# TODO: remove after buildds no longer pass to wanna-build
	"N|no-propagation" =>  => sub {
#	    $self->set_conf('DB_NO_PROPAGATION', 1); # <- $opt_no_propagation
	},
	# TODO: remove after buildds no longer pass to wanna-build
	"D|no-down-propagation" => sub {
#	    $self->set_conf('DB_NO_DOWN_PROPAGATION', 1); # <- $opt_no_down_propagation
	},
	# normal actions
	"take" => sub {
	    $self->set_conf('DB_OPERATION', 'set-building');
	},
	"f|failed" => sub {
	    $self->set_conf('DB_OPERATION', 'set-failed');
	},
	"u|uploaded" => sub {
	    $self->set_conf('DB_OPERATION', 'set-uploaded');
	},
	"n|no-build" => sub {
	    $self->set_conf('DB_OPERATION', 'set-not-for-us');
	},
	"built" => sub {
	    $self->set_conf('DB_OPERATION', 'set-built');
	},
	"attempted" => sub {
	    $self->set_conf('DB_OPERATION', 'set-attempted');
	},
	"give-back" => sub {
	    $self->set_conf('DB_OPERATION', 'set-needs-build');
	},
	"dep-wait" => sub {
	    $self->set_conf('DB_OPERATION', 'set-dep-wait');
	},
	"forget" => sub {
	    $self->set_conf('DB_OPERATION', 'forget');
	},
	"forget-user" => sub {
	    $self->set_conf('DB_OPERATION', 'forget-user');
	},
	"merge-all" => sub {
	    $self->set_conf('DB_OPERATION', 'merge-all');
	},
	"merge-quinn" => sub {
	    $self->set_conf('DB_OPERATION', 'merge-quinn');
	},
	"merge-partial-quinn" => sub {
	    $self->set_conf('DB_OPERATION',
			    'merge-partial-quinn');
	},
	"merge-packages" => sub {
	    $self->set_conf('DB_OPERATION', 'merge-packages');
	},
	"merge-sources" => sub {
	    $self->set_conf('DB_OPERATION', 'merge-sources');
	},
	"p|pretend-avail" => sub {
	    $self->set_conf('DB_OPERATION', 'pretend-avail');
	},
	"i|info" => sub {
	    $self->set_conf('DB_OPERATION', 'info');
	},

	# TODO: Move checks to Conf.pm.
	"binNMU=s" => sub {
	    die "Invalid binNMU version: $_[1]\n"
		if $_[1] !~ /^([\d]*)$/ and $1 >= 0;
	    $self->set_conf('DB_OPERATION', 'set-binary-nmu');
	    $self->set_conf('DB_BIN_NMU_VERSION', $_[1]); # <- $binNMUver
	},
	"perm-build-priority=s" => sub {
	    die "Invalid build priority: $_[1]\n"
		if $_[1] !~ /^-?[\d]+$/;
	    $self->set_conf('DB_OPERATION', 'set-permanent-build-priority');
	    $self->set_conf('DB_BUILD_PRIORITY', $_[1]); # <- $build_priority
	},
	"build-priority=s" => sub {
	    die "Invalid build priority: $_[1]\n"
		if $_[1] !~ /^-?[\d]+$/;
	    $self->set_conf('DB_OPERATION', 'set-build-priority');
	    $self->set_conf('DB_BUILD_PRIORITY', $_[1]); # <- $build_priority
	},
	"l|list=s" => sub {
	    die "Unknown state to list: $_[1]\n"
		if !isin( $_[1], qw(needs-build building uploaded
				    built build-attempted failed
				    installed dep-wait not-for-us all
				    failed-removed install-wait
				    reupload-wait));
	    $self->set_conf('DB_OPERATION', 'list');
	    $self->set_conf('DB_LIST_STATE', $_[1]); # <- $list_state
	},
	"O|order=s" => sub {
	    die "Bad ordering character\n"
		if $_[1] !~ /^[PSpsncb]+$/;
	    $self->set_conf('DB_LIST_ORDER', $_[1]); # <- $build_priority
	},
	"m|message=s" => sub {
	    $self->set_conf('DB_FAIL_REASON', $_[1]); # <- $fail_reason
	},
	"b|database=s" => sub {
	    $self->set_conf('DB_BASE_NAME', $_[1]); # <- $conf::dbbase
	},
	"A|arch=s" => sub {
	    $self->set_conf('ARCH', $_[1]); # <- $arch
	},
	"U|user=s" => sub {
	    $self->set_conf('DB_USER', $_[1]); # <- $user
	},
	"c|category=s" => sub {
	    my $category = category($_[1]);
	    die "Unknown category: $_[1]\n"
		if !defined($category);
	    $self->set_conf('DB_CATEGORY', $category); # <- $category
	},
	"a|min-age=i" => sub {
	    die "Minimum age must be a non-zero number\n"
		if $_[1] == 0;
	    $self->set_conf('DB_LIST_MIN_AGE', $_[1] * 24*60*60); # <- $list_min_age
	},
	"max-age=i" => sub {
	    die "Maximum age must be a non-zero number\n"
		if $_[1] == 0;
	    # NOTE: Negative value
	    $self->set_conf('DB_LIST_MIN_AGE', - $_[1] * 24*60*60); # <- $list_min_age
	},
	# special actions
	"import=s" => sub {
	    $self->set_conf('DB_OPERATION', 'import');
	    $self->set_conf('DB_IMPORT_FILE', $_[1]);
	},
	"export=s" => sub {
	    $self->set_conf('DB_OPERATION', 'export');
	    $self->set_conf('DB_EXPORT_FILE', $_[1]);
	},
	"manual-edit" => sub {
	    $self->set_conf('DB_OPERATION', 'manual-edit');
	},
	"create-maintenance-lock" => sub {
	    $self->set_conf('DB_OPERATION', 'maintlock-create');
	},
	"remove-maintenance-lock" => sub {
	    $self->set_conf('DB_OPERATION', 'maintlock-remove');
	},
	"clean-db" => sub {
	    $self->set_conf('DB_OPERATION', 'clean-db');
	},
    );
}

1;