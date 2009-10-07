# BEGIN BPS TAGGED BLOCK {{{
# 
# COPYRIGHT:
# 
# This software is Copyright (c) 1996-2009 Best Practical Solutions, LLC
#                                          <jesse@bestpractical.com>
# 
# (Except where explicitly superseded by other copyright notices)
# 
# 
# LICENSE:
# 
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
# 
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
# 
# 
# CONTRIBUTION SUBMISSION POLICY:
# 
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
# 
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
# 
# END BPS TAGGED BLOCK }}}

package RT::Ruleset;
use strict;
use warnings;

use base 'Class::Accessor::Fast';
use UNIVERSAL::require;

__PACKAGE__->mk_accessors(qw(name rules));

my @RULE_SETS;

sub find_all_rules {
    my ($class, %args) = @_;
    my $current_user = $args{ticket_obj}->current_user;

    return [
        grep { $_->prepare }
        map { $_->new(current_user => $current_user, %args) }
        grep { $_->_stage eq $args{stage} }
        map { @{$_->rules} } @RULE_SETS
    ];
}

sub commit_rules {
    my ($class, $rules) = @_;
    $_->commit
        for @$rules;
}

sub register {
    my ($class, $ruleset) = @_;
    push @RULE_SETS, $ruleset;
}

sub add {
    my ($class, %args) = @_;
    for (@{$args{rules}}) {
        $_->require or die $UNIVERSAL::require::ERROR;
    }
    $class->register($class->new(\%args));
}

1;