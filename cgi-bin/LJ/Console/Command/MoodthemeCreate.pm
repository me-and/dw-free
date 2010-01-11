# This code was forked from the LiveJournal project owned and operated
# by Live Journal, Inc. The code has been modified and expanded by
# Dreamwidth Studios, LLC. These files were originally licensed under
# the terms of the license supplied by Live Journal, Inc, which can
# currently be found at:
#
# http://code.livejournal.org/trac/livejournal/browser/trunk/LICENSE-LiveJournal.txt
#
# In accordance with the original license, this code and all its
# modifications are provided under the GNU General Public License.
# A copy of that license can be found in the LICENSE file included as
# part of this distribution.

package LJ::Console::Command::MoodthemeCreate;

use strict;
use base qw(LJ::Console::Command);
use Carp qw(croak);

sub cmd { "moodtheme_create" }

sub desc { "Create a new moodtheme. Returns the mood theme ID that you'll need to define moods for this theme." }

sub args_desc { [
                 'name' => "Name of this theme.",
                 'desc' => "A description of the theme",
                 ] }

sub usage { '<name> <desc>' }

sub can_execute { 1 }

sub execute {
    my ($self, $name, $desc, @args) = @_;

    return $self->error("This command takes two arguments. Consult the reference.")
        unless $name && $desc && scalar(@args) == 0;

    my $remote = LJ::get_remote();
    return $self->error("Sorry, your account type doesn't let you create new mood themes")
        unless $remote->can_create_moodthemes;

    my $dbh = LJ::get_db_writer();
    my $sth = $dbh->prepare("INSERT INTO moodthemes (ownerid, name, des, is_public) VALUES (?, ?, ?, 'N')");
    $sth->execute($remote->id, $name, $desc);

    my $mtid = $dbh->{'mysql_insertid'};
    return $self->print("Success. Your new mood theme ID is $mtid");
}

1;
