# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2013 Best Practical Solutions, LLC
#                                          <sales@bestpractical.com>
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

=head1 NAME

  RT::SearchBuilder - a baseclass for RT collection objects

=head1 SYNOPSIS

=head1 DESCRIPTION


=head1 METHODS




=cut

package RT::SearchBuilder;

use strict;
use warnings;

use base qw(DBIx::SearchBuilder RT::Base);

use RT::Base;
use DBIx::SearchBuilder "1.40";

use Scalar::Util qw/blessed/;

sub _Init  {
    my $self = shift;
    
    $self->{'user'} = shift;
    unless(defined($self->CurrentUser)) {
        use Carp;
        Carp::confess("$self was created without a CurrentUser");
        $RT::Logger->err("$self was created without a CurrentUser");
        return(0);
    }
    $self->SUPER::_Init( 'Handle' => $RT::Handle);
}

sub CleanSlate {
    my $self = shift;
    $self->{'_sql_aliases'} = {};
    return $self->SUPER::CleanSlate(@_);
}

sub JoinTransactions {
    my $self = shift;
    my %args = ( New => 0, @_ );

    return $self->{'_sql_aliases'}{'transactions'}
        if !$args{'New'} && $self->{'_sql_aliases'}{'transactions'};

    my $alias = $self->Join(
        ALIAS1 => 'main',
        FIELD1 => 'id',
        TABLE2 => 'Transactions',
        FIELD2 => 'ObjectId',
    );

    my $item = $self->NewItem;
    my $object_type = $item->can('ObjectType') ? $item->ObjectType : ref $item;

    $self->RT::SearchBuilder::Limit(
        LEFTJOIN => $alias,
        FIELD    => 'ObjectType',
        VALUE    => $object_type,
    );
    $self->{'_sql_aliases'}{'transactions'} = $alias
        unless $args{'New'};

    return $alias;
}

sub _OrderByCF {
    my $self = shift;
    my ($row, $cf) = @_;

    my $cfkey = blessed($cf) ? $cf->id : $cf;
    $cfkey .= ".ordering" if !blessed($cf) || ($cf->MaxValues||0) != 1;
    my ($ocfvs, $CFs) = $self->_CustomFieldJoin( $cfkey, $cf );
    # this is described in _LimitCustomField
    $self->Limit(
        ALIAS      => $CFs,
        FIELD      => 'Name',
        OPERATOR   => 'IS NOT',
        VALUE      => 'NULL',
        QUOTEVALUE => 1,
        ENTRYAGGREGATOR => 'AND',
    ) if $CFs;
    unless (blessed($cf)) {
        # For those cases where we are doing a join against the
        # CF name, and don't have a CFid, use Unique to make sure
        # we don't show duplicate tickets.  NOTE: I'm pretty sure
        # this will stay mixed in for the life of the
        # class/package, and not just for the life of the object.
        # Potential performance issue.
        require DBIx::SearchBuilder::Unique;
        DBIx::SearchBuilder::Unique->import;
    }
    my $CFvs = $self->Join(
        TYPE   => 'LEFT',
        ALIAS1 => $ocfvs,
        FIELD1 => 'CustomField',
        TABLE2 => 'CustomFieldValues',
        FIELD2 => 'CustomField',
    );
    $self->Limit(
        LEFTJOIN        => $CFvs,
        FIELD           => 'Name',
        QUOTEVALUE      => 0,
        VALUE           => "$ocfvs.Content",
        ENTRYAGGREGATOR => 'AND'
    );

    return { %$row, ALIAS => $CFvs,  FIELD => 'SortOrder' },
           { %$row, ALIAS => $ocfvs, FIELD => 'Content' };
}

sub OrderByCols {
    my $self = shift;
    my @sort;
    for my $s (@_) {
        next if defined $s->{FIELD} and $s->{FIELD} =~ /\W/;
        $s->{FIELD} = $s->{FUNCTION} if $s->{FUNCTION};
        push @sort, $s;
    }
    return $self->SUPER::OrderByCols( @sort );
}

# If we're setting RowsPerPage or FirstRow, ensure we get a natural number or undef.
sub RowsPerPage {
    my $self = shift;
    return if @_ and defined $_[0] and $_[0] =~ /\D/;
    return $self->SUPER::RowsPerPage(@_);
}

sub FirstRow {
    my $self = shift;
    return if @_ and defined $_[0] and $_[0] =~ /\D/;
    return $self->SUPER::FirstRow(@_);
}

=head2 LimitToEnabled

Only find items that haven't been disabled

=cut

sub LimitToEnabled {
    my $self = shift;

    $self->{'handled_disabled_column'} = 1;
    $self->Limit( FIELD => 'Disabled', VALUE => '0' );
}

=head2 LimitToDeleted

Only find items that have been deleted.

=cut

sub LimitToDeleted {
    my $self = shift;

    $self->{'handled_disabled_column'} = $self->{'find_disabled_rows'} = 1;
    $self->Limit( FIELD => 'Disabled', VALUE => '1' );
}

=head2 FindAllRows

Find all matching rows, regardless of whether they are disabled or not

=cut

sub FindAllRows {
    shift->{'find_disabled_rows'} = 1;
}

=head2 LimitCustomField

Takes a paramhash of key/value pairs with the following keys:

=over 4

=item CUSTOMFIELD - CustomField id. Optional

=item OPERATOR - The usual Limit operators

=item VALUE - The value to compare against

=back

=cut

sub _SingularClass {
    my $self = shift;
    my $class = ref($self);
    $class =~ s/s$// or die "Cannot deduce SingularClass for $class";
    return $class;
}

=head2 _CustomFieldJoin

Factor out the Join of custom fields so we can use it for sorting too

=cut

sub _CustomFieldJoin {
    my ($self, $cfkey, $cf) = @_;
    # Perform one Join per CustomField
    if ( $self->{_sql_object_cfv_alias}{$cfkey} ||
         $self->{_sql_cf_alias}{$cfkey} )
    {
        return ( $self->{_sql_object_cfv_alias}{$cfkey},
                 $self->{_sql_cf_alias}{$cfkey} );
    }

    my ($ocfvalias, $CFs);
    if ( blessed($cf) ) {
        $ocfvalias = $self->{_sql_object_cfv_alias}{$cfkey} = $self->Join(
            TYPE   => 'LEFT',
            ALIAS1 => 'main',
            FIELD1 => 'id',
            TABLE2 => 'ObjectCustomFieldValues',
            FIELD2 => 'ObjectId',
        );
        $self->Limit(
            LEFTJOIN        => $ocfvalias,
            FIELD           => 'CustomField',
            VALUE           => $cf->id,
            ENTRYAGGREGATOR => 'AND'
        );
    }
    else {
        my $ocfalias = $self->Join(
            TYPE       => 'LEFT',
            EXPRESSION => q|'0'|,
            TABLE2     => 'ObjectCustomFields',
            FIELD2     => 'ObjectId',
        );

        $self->Limit(
            LEFTJOIN        => $ocfalias,
            ENTRYAGGREGATOR => 'OR',
            FIELD           => 'ObjectId',
            VALUE           => 'main.Queue',
            QUOTEVALUE      => 0,
        ) if $self->isa("RT::Tickets");

        $CFs = $self->{_sql_cf_alias}{$cfkey} = $self->Join(
            TYPE       => 'LEFT',
            ALIAS1     => $ocfalias,
            FIELD1     => 'CustomField',
            TABLE2     => 'CustomFields',
            FIELD2     => 'id',
        );
        $self->Limit(
            LEFTJOIN        => $CFs,
            ENTRYAGGREGATOR => 'AND',
            FIELD           => 'LookupType',
            VALUE           => $self->NewItem->CustomFieldLookupType,
        );
        $self->Limit(
            LEFTJOIN        => $CFs,
            ENTRYAGGREGATOR => 'AND',
            FIELD           => 'Name',
            VALUE           => $cf,
        );

        $ocfvalias = $self->{_sql_object_cfv_alias}{$cfkey} = $self->Join(
            TYPE   => 'LEFT',
            ALIAS1 => $CFs,
            FIELD1 => 'id',
            TABLE2 => 'ObjectCustomFieldValues',
            FIELD2 => 'CustomField',
        );
        $self->Limit(
            LEFTJOIN        => $ocfvalias,
            FIELD           => 'ObjectId',
            VALUE           => 'main.id',
            QUOTEVALUE      => 0,
            ENTRYAGGREGATOR => 'AND',
        );
    }
    $self->Limit(
        LEFTJOIN        => $ocfvalias,
        FIELD           => 'ObjectType',
        VALUE           => ref($self->NewItem),
        ENTRYAGGREGATOR => 'AND'
    );
    $self->Limit(
        LEFTJOIN        => $ocfvalias,
        FIELD           => 'Disabled',
        OPERATOR        => '=',
        VALUE           => '0',
        ENTRYAGGREGATOR => 'AND'
    );

    return ($ocfvalias, $CFs);
}

sub LimitCustomField {
    my $self = shift;
    return $self->_LimitCustomField( @_ );
}

use Regexp::Common qw(RE_net_IPv4);
use Regexp::Common::net::CIDR;

sub _LimitCustomField {
    my $self = shift;
    my %args = ( VALUE        => undef,
                 CUSTOMFIELD  => undef,
                 OPERATOR     => '=',
                 KEY          => undef,
                 @_ );

    my $op     = delete $args{OPERATOR};
    my $value  = delete $args{VALUE};
    my $cf     = delete $args{CUSTOMFIELD};
    my $column = delete $args{COLUMN};
    my $cfkey  = delete $args{KEY};
    if (blessed($cf) and $cf->id) {
        $cfkey ||= $cf->id;
    } elsif ($cf =~ /^(\d+)$/) {
        $cf = RT::CustomField->new( $self->CurrentUser );
        $cf->Load($1);
        $cfkey ||= $cf->id;
    } else {
        $cfkey ||= $cf;
    }

    $args{SUBCLAUSE} ||= "cf-$cfkey";

# If we're trying to find custom fields that don't match something, we
# want tickets where the custom field has no value at all.  Note that
# we explicitly don't include the "IS NULL" case, since we would
# otherwise end up with a redundant clause.

    my $negative_op = ($op eq '!=' || $op =~ /\bNOT\b/i);
    my $null_op = ( 'is not' eq lc($op) || 'is' eq lc($op) );

    my $fix_op = sub {
        return @_ unless RT->Config->Get('DatabaseType') eq 'Oracle';

        my %args = @_;
        return %args unless $args{'FIELD'} eq 'LargeContent';
        
        my $op = $args{'OPERATOR'};
        if ( $op eq '=' ) {
            $args{'OPERATOR'} = 'MATCHES';
        }
        elsif ( $op eq '!=' ) {
            $args{'OPERATOR'} = 'NOT MATCHES';
        }
        elsif ( $op =~ /^[<>]=?$/ ) {
            $args{'FUNCTION'} = "TO_CHAR( $args{'ALIAS'}.LargeContent )";
        }
        return %args;
    };

    if ( blessed($cf) && $cf->Type eq 'IPAddress' ) {
        my $parsed = RT::ObjectCustomFieldValue->ParseIP($value);
        if ($parsed) {
            $value = $parsed;
        }
        else {
            $RT::Logger->warn("$value is not a valid IPAddress");
        }
    }

    if ( blessed($cf) && $cf->Type eq 'IPAddressRange' ) {

        if ( $value =~ /^\s*$RE{net}{CIDR}{IPv4}{-keep}\s*$/o ) {

            # convert incomplete 192.168/24 to 192.168.0.0/24 format
            $value =
              join( '.', map $_ || 0, ( split /\./, $1 )[ 0 .. 3 ] ) . "/$2"
              || $value;
        }

        my ( $start_ip, $end_ip ) =
          RT::ObjectCustomFieldValue->ParseIPRange($value);
        if ( $start_ip && $end_ip ) {
            if ( $op =~ /^([<>])=?$/ ) {
                my $is_less = $1 eq '<' ? 1 : 0;
                if ( $is_less ) {
                    $value = $start_ip;
                }
                else {
                    $value = $end_ip;
                }
            }
            else {
                $value = join '-', $start_ip, $end_ip;
            }
        }
        else {
            $RT::Logger->warn("$value is not a valid IPAddressRange");
        }
    }

    my $single_value = !blessed($cf) || $cf->SingleValue;

    if ( $null_op && !$column ) {
        # IS[ NOT] NULL without column is the same as has[ no] any CF value,
        # we can reuse our default joins for this operation
        # with column specified we have different situation
        my ($ocfvalias, $CFs) = $self->_CustomFieldJoin( $cfkey, $cf );
        $self->_OpenParen( $args{SUBCLAUSE} );
        $self->Limit(
            ALIAS    => $ocfvalias,
            FIELD    => 'id',
            OPERATOR => $op,
            VALUE    => $value,
            %args
        );
        $self->Limit(
            ALIAS      => $CFs,
            FIELD      => 'Name',
            OPERATOR   => 'IS NOT',
            VALUE      => 'NULL',
            QUOTEVALUE => 0,
            ENTRYAGGREGATOR => 'AND',
        ) if $CFs;
        $self->_CloseParen( $args{SUBCLAUSE} );
    }
    elsif ( $op !~ /^[<>]=?$/ && (  blessed($cf) && $cf->Type eq 'IPAddressRange')) {
        my ($start_ip, $end_ip) = split /-/, $value;
        $self->_OpenParen( $args{SUBCLAUSE} );
        if ( $op !~ /NOT|!=|<>/i ) { # positive equation
            $self->_LimitCustomField(
                OPERATOR    => '<=',
                VALUE       => $end_ip,
                CUSTOMFIELD => $cf,
                COLUMN      => 'Content',
                %args,
            );
            $self->_LimitCustomField(
                OPERATOR    => '>=',
                VALUE       => $start_ip,
                CUSTOMFIELD => $cf,
                COLUMN      => 'LargeContent',
                %args,
                ENTRYAGGREGATOR => 'AND',
            );
            # as well limit borders so DB optimizers can use better
            # estimations and scan less rows
# have to disable this tweak because of ipv6
#            $self->_CustomFieldLimit(
#                $field, '>=', '000.000.000.000', %rest,
#                SUBKEY          => $rest{'SUBKEY'}. '.Content',
#                ENTRYAGGREGATOR => 'AND',
#            );
#            $self->_CustomFieldLimit(
#                $field, '<=', '255.255.255.255', %rest,
#                SUBKEY          => $rest{'SUBKEY'}. '.LargeContent',
#                ENTRYAGGREGATOR => 'AND',
#            );  
        }       
        else { # negative equation
            $self->_LimitCustomField(
                OPERATOR    => '>',
                VALUE       => $end_ip,
                CUSTOMFIELD => $cf,
                COLUMN      => 'Content',
                %args,
            );
            $self->_LimitCustomField(
                OPERATOR    => '<',
                VALUE       => $start_ip,
                CUSTOMFIELD => $cf,
                COLUMN      => 'LargeContent',
                %args,
                ENTRYAGGREGATOR => 'OR',
            );
            # TODO: as well limit borders so DB optimizers can use better
            # estimations and scan less rows, but it's harder to do
            # as we have OR aggregator
        }
        $self->_CloseParen( $args{SUBCLAUSE} );
    } 
    elsif ( !$negative_op || $single_value ) {
        $cfkey .= '.'. $self->{'_sql_multiple_cfs_index'}++ if not $single_value and not $op =~ /^[<>]=?$/;
        my ($ocfvalias, $CFs) = $self->_CustomFieldJoin( $cfkey, $cf );

        $self->_OpenParen( $args{SUBCLAUSE} );
        $self->_OpenParen( $args{SUBCLAUSE} );
        $self->_OpenParen( $args{SUBCLAUSE} );
        # if column is defined then deal only with it
        # otherwise search in Content and in LargeContent
        if ( $column ) {
            $self->Limit( $fix_op->(
                ALIAS      => $ocfvalias,
                FIELD      => $column,
                OPERATOR   => $op,
                VALUE      => $value,
                CASESENSITIVE => 0,
                %args
            ) );
            $self->_CloseParen( $args{SUBCLAUSE} );
            $self->_CloseParen( $args{SUBCLAUSE} );
            $self->_CloseParen( $args{SUBCLAUSE} );
        }
        else {
            # need special treatment for Date
            if ( blessed($cf) and $cf->Type eq 'DateTime' and $op eq '=' ) {

                if ( $value =~ /:/ ) {
                    # there is time speccified.
                    my $date = RT::Date->new( $self->CurrentUser );
                    $date->Set( Format => 'unknown', Value => $value );
                    $self->Limit(
                        ALIAS    => $ocfvalias,
                        FIELD    => 'Content',
                        OPERATOR => "=",
                        VALUE    => $date->ISO,
                        %args,
                    );
                }
                else {
                # no time specified, that means we want everything on a
                # particular day.  in the database, we need to check for >
                # and < the edges of that day.
                    my $date = RT::Date->new( $self->CurrentUser );
                    $date->Set( Format => 'unknown', Value => $value );
                    $date->SetToMidnight( Timezone => 'server' );
                    my $daystart = $date->ISO;
                    $date->AddDay;
                    my $dayend = $date->ISO;

                    $self->_OpenParen( $args{SUBCLAUSE} );

                    $self->Limit(
                        ALIAS    => $ocfvalias,
                        FIELD    => 'Content',
                        OPERATOR => ">=",
                        VALUE    => $daystart,
                        %args,
                    );

                    $self->Limit(
                        ALIAS    => $ocfvalias,
                        FIELD    => 'Content',
                        OPERATOR => "<=",
                        VALUE    => $dayend,
                        %args,
                        ENTRYAGGREGATOR => 'AND',
                    );

                    $self->_CloseParen( $args{SUBCLAUSE} );
                }
            }
            elsif ( $op eq '=' || $op eq '!=' || $op eq '<>' ) {
                if ( length( Encode::encode_utf8($value) ) < 256 ) {
                    $self->Limit(
                        ALIAS    => $ocfvalias,
                        FIELD    => 'Content',
                        OPERATOR => $op,
                        VALUE    => $value,
                        CASESENSITIVE => 0,
                        %args
                    );
                }
                else {
                    $self->_OpenParen( $args{SUBCLAUSE} );
                    $self->Limit(
                        ALIAS           => $ocfvalias,
                        FIELD           => 'Content',
                        OPERATOR        => '=',
                        VALUE           => '',
                        ENTRYAGGREGATOR => 'OR',
                        SUBCLAUSE       => $args{SUBCLAUSE},
                    );
                    $self->Limit(
                        ALIAS           => $ocfvalias,
                        FIELD           => 'Content',
                        OPERATOR        => 'IS',
                        VALUE           => 'NULL',
                        SUBCLAUSE       => $args{SUBCLAUSE},
                        ENTRYAGGREGATOR => 'OR'
                    );
                    $self->_CloseParen( $args{SUBCLAUSE} );
                    $self->Limit( $fix_op->(
                        ALIAS           => $ocfvalias,
                        FIELD           => 'LargeContent',
                        OPERATOR        => $op,
                        VALUE           => $value,
                        ENTRYAGGREGATOR => 'AND',
                        SUBCLAUSE       => $args{SUBCLAUSE},
                        CASESENSITIVE => 0,
                    ) );
                }
            }
            else {
                $self->Limit(
                    ALIAS    => $ocfvalias,
                    FIELD    => 'Content',
                    OPERATOR => $op,
                    VALUE    => $value,
                    CASESENSITIVE => 0,
                    %args
                );

                $self->_OpenParen( $args{SUBCLAUSE} );
                $self->_OpenParen( $args{SUBCLAUSE} );
                $self->Limit(
                    ALIAS           => $ocfvalias,
                    FIELD           => 'Content',
                    OPERATOR        => '=',
                    VALUE           => '',
                    SUBCLAUSE       => $args{SUBCLAUSE},
                    ENTRYAGGREGATOR => 'OR'
                );
                $self->Limit(
                    ALIAS           => $ocfvalias,
                    FIELD           => 'Content',
                    OPERATOR        => 'IS',
                    VALUE           => 'NULL',
                    SUBCLAUSE       => $args{SUBCLAUSE},
                    ENTRYAGGREGATOR => 'OR'
                );
                $self->_CloseParen( $args{SUBCLAUSE} );
                $self->Limit( $fix_op->(
                    ALIAS           => $ocfvalias,
                    FIELD           => 'LargeContent',
                    OPERATOR        => $op,
                    VALUE           => $value,
                    ENTRYAGGREGATOR => 'AND',
                    SUBCLAUSE       => $args{SUBCLAUSE},
                    CASESENSITIVE => 0,
                ) );
                $self->_CloseParen( $args{SUBCLAUSE} );
            }
            $self->_CloseParen( $args{SUBCLAUSE} );

            # XXX: if we join via CustomFields table then
            # because of order of left joins we get NULLs in
            # CF table and then get nulls for those records
            # in OCFVs table what result in wrong results
            # as decifer method now tries to load a CF then
            # we fall into this situation only when there
            # are more than one CF with the name in the DB.
            # the same thing applies to order by call.
            # TODO: reorder joins T <- OCFVs <- CFs <- OCFs if
            # we want treat IS NULL as (not applies or has
            # no value)
            $self->Limit(
                ALIAS           => $CFs,
                FIELD           => 'Name',
                OPERATOR        => 'IS NOT',
                VALUE           => 'NULL',
                QUOTEVALUE      => 0,
                ENTRYAGGREGATOR => 'AND',
            ) if $CFs;
            $self->_CloseParen( $args{SUBCLAUSE} );

            if ($negative_op) {
                $self->Limit(
                    ALIAS           => $ocfvalias,
                    FIELD           => $column || 'Content',
                    OPERATOR        => 'IS',
                    VALUE           => 'NULL',
                    QUOTEVALUE      => 0,
                    ENTRYAGGREGATOR => 'OR',
                );
            }

            $self->_CloseParen( $args{SUBCLAUSE} );
        }
    }
    else {
        $cfkey .= '.'. $self->{'_sql_multiple_cfs_index'}++;
        my ($ocfvalias, $CFs) = $self->_CustomFieldJoin( $cfkey, $cf );

        # reverse operation
        $op =~ s/!|NOT\s+//i;

        # if column is defined then deal only with it
        # otherwise search in Content and in LargeContent
        if ( $column ) {
            $self->Limit( $fix_op->(
                LEFTJOIN   => $ocfvalias,
                ALIAS      => $ocfvalias,
                FIELD      => $column,
                OPERATOR   => $op,
                VALUE      => $value,
                CASESENSITIVE => 0,
            ) );
        }
        else {
            $self->Limit(
                LEFTJOIN   => $ocfvalias,
                ALIAS      => $ocfvalias,
                FIELD      => 'Content',
                OPERATOR   => $op,
                VALUE      => $value,
                CASESENSITIVE => 0,
            );
        }
        $self->Limit(
            %args,
            ALIAS      => $ocfvalias,
            FIELD      => 'id',
            OPERATOR   => 'IS',
            VALUE      => 'NULL',
            QUOTEVALUE => 0,
        );
    }
}

=head2 Limit PARAMHASH

This Limit sub calls SUPER::Limit, but defaults "CASESENSITIVE" to 1, thus
making sure that by default lots of things don't do extra work trying to 
match lower(colname) agaist lc($val);

We also force VALUE to C<NULL> when the OPERATOR is C<IS> or C<IS NOT>.
This ensures that we don't pass invalid SQL to the database or allow SQL
injection attacks when we pass through user specified values.

=cut

sub Limit {
    my $self = shift;
    my %ARGS = (
        CASESENSITIVE => 1,
        OPERATOR => '=',
        @_,
    );

    # We use the same regex here that DBIx::SearchBuilder uses to exclude
    # values from quoting
    if ( $ARGS{'OPERATOR'} =~ /IS/i ) {
        # Don't pass anything but NULL for IS and IS NOT
        $ARGS{'VALUE'} = 'NULL';
    }

    if ($ARGS{FUNCTION}) {
        ($ARGS{ALIAS}, $ARGS{FIELD}) = split /\./, delete $ARGS{FUNCTION}, 2;
        $self->SUPER::Limit(%ARGS);
    } elsif ($ARGS{FIELD} =~ /\W/
          or $ARGS{OPERATOR} !~ /^(=|<|>|!=|<>|<=|>=
                                  |(NOT\s*)?LIKE
                                  |(NOT\s*)?(STARTS|ENDS)WITH
                                  |(NOT\s*)?MATCHES
                                  |IS(\s*NOT)?
                                  |IN
                                  |\@\@)$/ix) {
        $RT::Logger->crit("Possible SQL injection attack: $ARGS{FIELD} $ARGS{OPERATOR}");
        $self->SUPER::Limit(
            %ARGS,
            FIELD    => 'id',
            OPERATOR => '<',
            VALUE    => '0',
        );
    } else {
        $self->SUPER::Limit(%ARGS);
    }
}

=head2 ItemsOrderBy

If it has a SortOrder attribute, sort the array by SortOrder.
Otherwise, if it has a "Name" attribute, sort alphabetically by Name
Otherwise, just give up and return it in the order it came from the
db.

=cut

sub ItemsOrderBy {
    my $self = shift;
    my $items = shift;
  
    if ($self->NewItem()->_Accessible('SortOrder','read')) {
        $items = [ sort { $a->SortOrder <=> $b->SortOrder } @{$items} ];
    }
    elsif ($self->NewItem()->_Accessible('Name','read')) {
        $items = [ sort { lc($a->Name) cmp lc($b->Name) } @{$items} ];
    }

    return $items;
}

=head2 ItemsArrayRef

Return this object's ItemsArray, in the order that ItemsOrderBy sorts
it.

=cut

sub ItemsArrayRef {
    my $self = shift;
    return $self->ItemsOrderBy($self->SUPER::ItemsArrayRef());
}

# make sure that Disabled rows never get seen unless
# we're explicitly trying to see them.

sub _DoSearch {
    my $self = shift;

    if ( $self->{'with_disabled_column'}
        && !$self->{'handled_disabled_column'}
        && !$self->{'find_disabled_rows'}
    ) {
        $self->LimitToEnabled;
    }
    return $self->SUPER::_DoSearch(@_);
}
sub _DoCount {
    my $self = shift;

    if ( $self->{'with_disabled_column'}
        && !$self->{'handled_disabled_column'}
        && !$self->{'find_disabled_rows'}
    ) {
        $self->LimitToEnabled;
    }
    return $self->SUPER::_DoCount(@_);
}

=head2 ColumnMapClassName

ColumnMap needs a Collection name to load the correct list display.
Depluralization is hard, so provide an easy way to correct the naive
algorithm that this code uses.

=cut

sub ColumnMapClassName {
    my $self = shift;
    my $Class = ref $self;
    $Class =~ s/s$//;
    $Class =~ s/:/_/g;
    return $Class;
}

RT::Base->_ImportOverlays();

1;
