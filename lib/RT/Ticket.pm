# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2012 Best Practical Solutions, LLC
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

=head1 SYNOPSIS

  use RT::Ticket;
  my $ticket = RT::Ticket->new($CurrentUser);
  $ticket->Load($ticket_id);

=head1 DESCRIPTION

This module lets you manipulate RT's ticket object.


=head1 METHODS


=cut


package RT::Ticket;

use strict;
use warnings;


use RT::Queue;
use RT::User;
use RT::Record;
use RT::Link;
use RT::Links;
use RT::Date;
use RT::CustomFields;
use RT::Tickets;
use RT::Transactions;
use RT::Reminders;
use RT::URI::fsck_com_rt;
use RT::URI;
use MIME::Entity;
use Devel::GlobalDestruction;

my %ROLES = (
    # name    =>  description
    Owner     => 'The owner of a ticket',                             # loc_pair
    Requestor => 'The requestor of a ticket',                         # loc_pair
    Cc        => 'The CC of a ticket',                                # loc_pair
    AdminCc   => 'The administrative CC of a ticket',                 # loc_pair
);

for my $role (sort keys %ROLES) {
    RT::Ticket->RegisterRole(
        Name            => $role,
        EquivClasses    => ['RT::Queue'],
        ( $role eq "Owner" ? ( Column => "Owner") : () ),
    );
}

our %MERGE_CACHE = (
    effective => {},
    merged => {},
);


=head2 Load

Takes a single argument. This can be a ticket id, ticket alias or 
local ticket uri.  If the ticket can't be loaded, returns undef.
Otherwise, returns the ticket id.

=cut

sub Load {
    my $self = shift;
    my $id   = shift;
    $id = '' unless defined $id;

    # TODO: modify this routine to look at EffectiveId and
    # do the recursive load thing. be careful to cache all
    # the interim tickets we try so we don't loop forever.

    unless ( $id =~ /^\d+$/ ) {
        $RT::Logger->debug("Tried to load a bogus ticket id: '$id'");
        return (undef);
    }

    $id = $MERGE_CACHE{'effective'}{ $id }
        if $MERGE_CACHE{'effective'}{ $id };

    my ($ticketid, $msg) = $self->LoadById( $id );
    unless ( $self->Id ) {
        $RT::Logger->debug("$self tried to load a bogus ticket: $id");
        return (undef);
    }

    #If we're merged, resolve the merge.
    if ( $self->EffectiveId && $self->EffectiveId != $self->Id ) {
        $RT::Logger->debug(
            "We found a merged ticket. "
            . $self->id ."/". $self->EffectiveId
        );
        my $real_id = $self->Load( $self->EffectiveId );
        $MERGE_CACHE{'effective'}{ $id } = $real_id;
        return $real_id;
    }

    #Ok. we're loaded. lets get outa here.
    return $self->Id;
}



=head2 Create (ARGS)

Arguments: ARGS is a hash of named parameters.  Valid parameters are:

  id 
  Queue  - Either a Queue object or a Queue Name
  Requestor -  A reference to a list of  email addresses or RT user Names
  Cc  - A reference to a list of  email addresses or Names
  AdminCc  - A reference to a  list of  email addresses or Names
  SquelchMailTo - A reference to a list of email addresses - 
                  who should this ticket not mail
  Type -- The ticket's type. ignore this for now
  Owner -- This ticket's owner. either an RT::User object or this user's id
  Subject -- A string describing the subject of the ticket
  Priority -- an integer from 0 to 99
  InitialPriority -- an integer from 0 to 99
  FinalPriority -- an integer from 0 to 99
  Status -- any valid status (Defined in RT::Queue)
  TimeEstimated -- an integer. estimated time for this task in minutes
  TimeWorked -- an integer. time worked so far in minutes
  TimeLeft -- an integer. time remaining in minutes
  Starts -- an ISO date describing the ticket's start date and time in GMT
  Due -- an ISO date describing the ticket's due date and time in GMT
  MIMEObj -- a MIME::Entity object with the content of the initial ticket request.
  CustomField-<n> -- a scalar or array of values for the customfield with the id <n>

Ticket links can be set up during create by passing the link type as a hask key and
the ticket id to be linked to as a value (or a URI when linking to other objects).
Multiple links of the same type can be created by passing an array ref. For example:

  Parents => 45,
  DependsOn => [ 15, 22 ],
  RefersTo => 'http://www.bestpractical.com',

Supported link types are C<MemberOf>, C<HasMember>, C<RefersTo>, C<ReferredToBy>,
C<DependsOn> and C<DependedOnBy>. Also, C<Parents> is alias for C<MemberOf> and
C<Members> and C<Children> are aliases for C<HasMember>.

Returns: TICKETID, Transaction Object, Error Message


=cut

sub Create {
    my $self = shift;

    my %args = (
        id                 => undef,
        EffectiveId        => undef,
        Queue              => undef,
        Requestor          => undef,
        Cc                 => undef,
        AdminCc            => undef,
        SquelchMailTo      => undef,
        TransSquelchMailTo => undef,
        Type               => 'ticket',
        Owner              => undef,
        Subject            => '',
        InitialPriority    => undef,
        FinalPriority      => undef,
        Priority           => undef,
        Status             => undef,
        TimeWorked         => "0",
        TimeLeft           => 0,
        TimeEstimated      => 0,
        Due                => undef,
        Starts             => undef,
        Started            => undef,
        Resolved           => undef,
        MIMEObj            => undef,
        _RecordTransaction => 1,
        DryRun             => 0,
        @_
    );

    my ($ErrStr, @non_fatal_errors);

    my $QueueObj = RT::Queue->new( RT->SystemUser );
    if ( ref $args{'Queue'} eq 'RT::Queue' ) {
        $QueueObj->Load( $args{'Queue'}->Id );
    }
    elsif ( $args{'Queue'} ) {
        $QueueObj->Load( $args{'Queue'} );
    }
    else {
        $RT::Logger->debug("'". ( $args{'Queue'} ||''). "' not a recognised queue object." );
    }

    #Can't create a ticket without a queue.
    unless ( $QueueObj->Id ) {
        $RT::Logger->debug("$self No queue given for ticket creation.");
        return ( 0, 0, $self->loc('Could not create ticket. Queue not set') );
    }


    #Now that we have a queue, Check the ACLS
    unless (
        $self->CurrentUser->HasRight(
            Right  => 'CreateTicket',
            Object => $QueueObj
        ) and $QueueObj->Disabled != 1
      )
    {
        return (
            0, 0,
            $self->loc( "No permission to create tickets in the queue '[_1]'", $QueueObj->Name));
    }

    my $cycle = $QueueObj->LifecycleObj;
    unless ( defined $args{'Status'} && length $args{'Status'} ) {
        $args{'Status'} = $cycle->DefaultOnCreate;
    }

    unless ( $cycle->IsValid( $args{'Status'} ) ) {
        return ( 0, 0,
            $self->loc("Status '[_1]' isn't a valid status for tickets in this queue.",
                $self->loc($args{'Status'}))
        );
    }

    unless ( $cycle->IsTransition( '' => $args{'Status'} ) ) {
        return ( 0, 0,
            $self->loc("New tickets can not have status '[_1]' in this queue.",
                $self->loc($args{'Status'}))
        );
    }



    #Since we have a queue, we can set queue defaults

    #Initial Priority
    # If there's no queue default initial priority and it's not set, set it to 0
    $args{'InitialPriority'} = $QueueObj->InitialPriority || 0
        unless defined $args{'InitialPriority'};

    #Final priority
    # If there's no queue default final priority and it's not set, set it to 0
    $args{'FinalPriority'} = $QueueObj->FinalPriority || 0
        unless defined $args{'FinalPriority'};

    # Priority may have changed from InitialPriority, for the case
    # where we're importing tickets (eg, from an older RT version.)
    $args{'Priority'} = $args{'InitialPriority'}
        unless defined $args{'Priority'};

    # Dates
    #TODO we should see what sort of due date we're getting, rather +
    # than assuming it's in ISO format.

    #Set the due date. if we didn't get fed one, use the queue default due in
    my $Due = RT::Date->new( $self->CurrentUser );
    if ( defined $args{'Due'} ) {
        $Due->Set( Format => 'ISO', Value => $args{'Due'} );
    }
    elsif ( my $due_in = $QueueObj->DefaultDueIn ) {
        $Due->SetToNow;
        $Due->AddDays( $due_in );
    }

    my $Starts = RT::Date->new( $self->CurrentUser );
    if ( defined $args{'Starts'} ) {
        $Starts->Set( Format => 'ISO', Value => $args{'Starts'} );
    }

    my $Started = RT::Date->new( $self->CurrentUser );
    if ( defined $args{'Started'} ) {
        $Started->Set( Format => 'ISO', Value => $args{'Started'} );
    }

    # If the status is not an initial status, set the started date
    elsif ( !$cycle->IsInitial($args{'Status'}) ) {
        $Started->SetToNow;
    }

    my $Resolved = RT::Date->new( $self->CurrentUser );
    if ( defined $args{'Resolved'} ) {
        $Resolved->Set( Format => 'ISO', Value => $args{'Resolved'} );
    }

    #If the status is an inactive status, set the resolved date
    elsif ( $cycle->IsInactive( $args{'Status'} ) )
    {
        $RT::Logger->debug( "Got a ". $args{'Status'}
            ."(inactive) ticket with undefined resolved date. Setting to now."
        );
        $Resolved->SetToNow;
    }

    # Dealing with time fields
    $args{'TimeEstimated'} = 0 unless defined $args{'TimeEstimated'};
    $args{'TimeWorked'}    = 0 unless defined $args{'TimeWorked'};
    $args{'TimeLeft'}      = 0 unless defined $args{'TimeLeft'};

    # Figure out users for roles
    my $roles = {};
    push @non_fatal_errors, $self->_ResolveRoles( $roles, %args );

    $RT::Handle->BeginTransaction();

    my %params = (
        Queue           => $QueueObj->Id,
        Subject         => $args{'Subject'},
        InitialPriority => $args{'InitialPriority'},
        FinalPriority   => $args{'FinalPriority'},
        Priority        => $args{'Priority'},
        Status          => $args{'Status'},
        TimeWorked      => $args{'TimeWorked'},
        TimeEstimated   => $args{'TimeEstimated'},
        TimeLeft        => $args{'TimeLeft'},
        Type            => $args{'Type'},
        Starts          => $Starts->ISO,
        Started         => $Started->ISO,
        Resolved        => $Resolved->ISO,
        Due             => $Due->ISO
    );

# Parameters passed in during an import that we probably don't want to touch, otherwise
    foreach my $attr (qw(id Creator Created LastUpdated LastUpdatedBy)) {
        $params{$attr} = $args{$attr} if $args{$attr};
    }

    # Delete null integer parameters
    foreach my $attr
        (qw(TimeWorked TimeLeft TimeEstimated InitialPriority FinalPriority))
    {
        delete $params{$attr}
          unless ( exists $params{$attr} && $params{$attr} );
    }

    # Delete the time worked if we're counting it in the transaction
    delete $params{'TimeWorked'} if $args{'_RecordTransaction'};

    my ($id,$ticket_message) = $self->SUPER::Create( %params );
    unless ($id) {
        $RT::Logger->crit( "Couldn't create a ticket: " . $ticket_message );
        $RT::Handle->Rollback();
        return ( 0, 0,
            $self->loc("Ticket could not be created due to an internal error")
        );
    }

    #Set the ticket's effective ID now that we've created it.
    my ( $val, $msg ) = $self->__Set(
        Field => 'EffectiveId',
        Value => ( $args{'EffectiveId'} || $id )
    );
    unless ( $val ) {
        $RT::Logger->crit("Couldn't set EffectiveId: $msg");
        $RT::Handle->Rollback;
        return ( 0, 0,
            $self->loc("Ticket could not be created due to an internal error")
        );
    }

    # Create (empty) role groups
    my $create_groups_ret = $self->_CreateRoleGroups();
    unless ($create_groups_ret) {
        $RT::Logger->crit( "Couldn't create ticket groups for ticket "
              . $self->Id
              . ". aborting Ticket creation." );
        $RT::Handle->Rollback();
        return ( 0, 0,
            $self->loc("Ticket could not be created due to an internal error")
        );
    }

    # Codify what it takes to add each kind of group
    my %acls = (
        Cc        => sub { 1 },
        Requestor => sub { 1 },
        AdminCc   => sub {
            my $principal = shift;
            return 1 if $self->CurrentUserHasRight('ModifyTicket');
            return $principal->id == $self->CurrentUser->PrincipalId
                and $self->CurrentUserHasRight("WatchAsAdminCc");
        },
        Owner     => sub {
            my $principal = shift;
            return 1 if $principal->id == RT->Nobody->PrincipalId;
            return $principal->HasRight( Object => $self, Right => 'OwnTicket' );
        },
    );

    # Populate up the role groups.  This call modifies $roles.
    push @non_fatal_errors, $self->_AddRolesOnCreate( $roles, %acls );

    # Squelching
    if ($args{'SquelchMailTo'}) {
       my @squelch = ref( $args{'SquelchMailTo'} ) ? @{ $args{'SquelchMailTo'} }
        : $args{'SquelchMailTo'};
        $self->_SquelchMailTo( @squelch );
    }

    # Add all the custom fields
    foreach my $arg ( keys %args ) {
        next unless $arg =~ /^CustomField-(\d+)$/i;
        my $cfid = $1;

        foreach my $value (
            UNIVERSAL::isa( $args{$arg} => 'ARRAY' ) ? @{ $args{$arg} } : ( $args{$arg} ) )
        {
            next unless defined $value && length $value;

            # Allow passing in uploaded LargeContent etc by hash reference
            my ($status, $msg) = $self->_AddCustomFieldValue(
                (UNIVERSAL::isa( $value => 'HASH' )
                    ? %$value
                    : (Value => $value)
                ),
                Field             => $cfid,
                RecordTransaction => 0,
            );
            push @non_fatal_errors, $msg unless $status;
        }
    }

    # Deal with setting up links

    # TODO: Adding link may fire scrips on other end and those scrips
    # could create transactions on this ticket before 'Create' transaction.
    #
    # We should implement different lifecycle: record 'Create' transaction,
    # create links and only then fire create transaction's scrips.
    #
    # Ideal variant: add all links without firing scrips, record create
    # transaction and only then fire scrips on the other ends of links.
    #
    # //RUZ

    foreach my $type ( keys %RT::Link::TYPEMAP ) {
        next unless ( defined $args{$type} );
        foreach my $link (
            ref( $args{$type} ) ? @{ $args{$type} } : ( $args{$type} ) )
        {
            my ( $val, $msg, $obj ) = $self->__GetTicketFromURI( URI => $link );
            unless ($val) {
                push @non_fatal_errors, $msg;
                next;
            }

            # Check rights on the other end of the link if we must
            # then run _AddLink that doesn't check for ACLs
            if ( RT->Config->Get( 'StrictLinkACL' ) ) {
                if ( $obj && !$obj->CurrentUserHasRight('ModifyTicket') ) {
                    push @non_fatal_errors, $self->loc('Linking. Permission denied');
                    next;
                }
            }

            if ( $obj && $obj->Status eq 'deleted' ) {
                push @non_fatal_errors,
                  $self->loc("Linking. Can't link to a deleted ticket");
                next;
            }

            my ( $wval, $wmsg ) = $self->_AddLink(
                Type                          => $RT::Link::TYPEMAP{$type}->{'Type'},
                $RT::Link::TYPEMAP{$type}->{'Mode'} => $link,
                Silent                        => !$args{'_RecordTransaction'} || $self->Type eq 'reminder',
                'Silent'. ( $RT::Link::TYPEMAP{$type}->{'Mode'} eq 'Base'? 'Target': 'Base' )
                                              => 1,
            );

            push @non_fatal_errors, $wmsg unless ($wval);
        }
    }

    # Try to add roles once more.
    push @non_fatal_errors, $self->_AddRolesOnCreate( $roles, %acls );

    # Anything left is failure of ACLs; Cc and Requestor have no ACLs,
    # so we don't bother checking them.
    if (@{ $roles->{Owner} }) {
        my $owner = $roles->{Owner}[0]->Object;
        $RT::Logger->warning( "User " . $owner->Name . "(" . $owner->id
                . ") was proposed as a ticket owner but has no rights to own "
                . "tickets in " . $QueueObj->Name );
        push @non_fatal_errors, $self->loc(
            "Owner '[_1]' does not have rights to own this ticket.",
            $owner->Name
        );
    }
    for my $principal (@{ $roles->{AdminCc} }) {
        push @non_fatal_errors, $self->loc(
            "No rights to add '[_1]' as an AdminCc on this ticket",
            $principal->Object->Name
        );
    }

    if ( $args{'_RecordTransaction'} ) {

        # Add a transaction for the create
        my ( $Trans, $Msg, $TransObj ) = $self->_NewTransaction(
            Type         => "Create",
            TimeTaken    => $args{'TimeWorked'},
            MIMEObj      => $args{'MIMEObj'},
            CommitScrips => !$args{'DryRun'},
            SquelchMailTo => $args{'TransSquelchMailTo'},
        );

        if ( $self->Id && $Trans ) {

            $TransObj->UpdateCustomFields( %args );

            $RT::Logger->info( "Ticket " . $self->Id . " created in queue '" . $QueueObj->Name . "' by " . $self->CurrentUser->Name );
            $ErrStr = $self->loc( "Ticket [_1] created in queue '[_2]'", $self->Id, $QueueObj->Name );
            $ErrStr = join( "\n", $ErrStr, @non_fatal_errors );
        }
        else {
            $RT::Handle->Rollback();

            $ErrStr = join( "\n", $ErrStr, @non_fatal_errors );
            $RT::Logger->error("Ticket couldn't be created: $ErrStr");
            return ( 0, 0, $self->loc( "Ticket could not be created due to an internal error"));
        }

        if ( $args{'DryRun'} ) {
            $RT::Handle->Rollback();
            return ($self->id, $TransObj, $ErrStr);
        }
        $RT::Handle->Commit();
        return ( $self->Id, $TransObj->Id, $ErrStr );
    }
    else {

        # Not going to record a transaction
        $RT::Handle->Commit();
        $ErrStr = $self->loc( "Ticket [_1] created in queue '[_2]'", $self->Id, $QueueObj->Name );
        $ErrStr = join( "\n", $ErrStr, @non_fatal_errors );
        return ( $self->Id, 0, $ErrStr );

    }
}




=head2 _Parse822HeadersForAttributes Content

Takes an RFC822 style message and parses its attributes into a hash.

=cut

sub _Parse822HeadersForAttributes {
    my $self    = shift;
    my $content = shift;
    my %args;

    my @lines = ( split ( /\n/, $content ) );
    while ( defined( my $line = shift @lines ) ) {
        if ( $line =~ /^(.*?):(?:\s+(.*))?$/ ) {
            my $value = $2;
            my $tag   = lc($1);

            $tag =~ s/-//g;
            if ( defined( $args{$tag} ) )
            {    #if we're about to get a second value, make it an array
                $args{$tag} = [ $args{$tag} ];
            }
            if ( ref( $args{$tag} ) )
            {    #If it's an array, we want to push the value
                push @{ $args{$tag} }, $value;
            }
            else {    #if there's nothing there, just set the value
                $args{$tag} = $value;
            }
        } elsif ($line =~ /^$/) {

            #TODO: this won't work, since "" isn't of the form "foo:value"

                while ( defined( my $l = shift @lines ) ) {
                    push @{ $args{'content'} }, $l;
                }
            }
        
    }

    foreach my $date (qw(due starts started resolved)) {
        my $dateobj = RT::Date->new(RT->SystemUser);
        if ( defined ($args{$date}) and $args{$date} =~ /^\d+$/ ) {
            $dateobj->Set( Format => 'unix', Value => $args{$date} );
        }
        else {
            $dateobj->Set( Format => 'unknown', Value => $args{$date} );
        }
        $args{$date} = $dateobj->ISO;
    }
    $args{'mimeobj'} = MIME::Entity->new();
    $args{'mimeobj'}->build(
        Type => ( $args{'contenttype'} || 'text/plain' ),
        Data => ($args{'content'} || '')
    );

    return (%args);
}

=head2 OwnerGroup

A constructor which returns an RT::Group object containing the owner of this ticket.

=cut

sub OwnerGroup {
    my $self = shift;
    return $self->RoleGroup( 'Owner' );
}


sub _HasModifyWatcherRight {
    my $self = shift;
    my ($type, $principal) = @_;

    # ModifyTicket works in any case
    return 1 if $self->CurrentUserHasRight('ModifyTicket');
    # If the watcher isn't the current user then the current user has no right
    return 0 unless $self->CurrentUser->PrincipalId == $principal->id;
    # If it's an AdminCc and they don't have 'WatchAsAdminCc', bail
    return 0 if $type eq 'AdminCc' and not $self->CurrentUserHasRight('WatchAsAdminCc');
    # If it's a Requestor or Cc and they don't have 'Watch', bail
    return 0 if ($type eq "Cc" or $type eq 'Requestor')
        and not $self->CurrentUserHasRight('Watch');
    return 1;
}


=head2 AddWatcher

Applies access control checking, then calls L<RT::Record/AddRoleMember>.
Additionally, C<Email> is accepted as an alternative argument name for
C<User>.

Returns a tuple of (status, message).

=cut

sub AddWatcher {
    my $self = shift;
    my %args = (
        Type  => undef,
        PrincipalId => undef,
        Email => undef,
        @_
    );

    $args{ACL} = sub { $self->_HasModifyWatcherRight( @_ ) };
    $args{User} ||= delete $args{Email};
    my ($principal, $msg) = $self->AddRoleMember(
        %args,
        InsideTransaction => 1,
    );
    return ( 0, $msg) unless $principal;

    return ( 1, $self->loc('Added [_1] as a [_2] for this ticket',
                $principal->Object->Name, $self->loc($args{'Type'})) );
}


=head2 DeleteWatcher

Applies access control checking, then calls L<RT::Record/DeleteRoleMember>.
Additionally, C<Email> is accepted as an alternative argument name for
C<User>.

Returns a tuple of (status, message).

=cut


sub DeleteWatcher {
    my $self = shift;

    my %args = ( Type        => undef,
                 PrincipalId => undef,
                 Email       => undef,
                 @_ );

    $args{ACL} = sub { $self->_HasModifyWatcherRight( @_ ) };
    $args{User} ||= delete $args{Email};
    my ($principal, $msg) = $self->DeleteRoleMember( %args );
    return ( 0, $msg ) unless $principal;

    return ( 1,
             $self->loc( "[_1] is no longer a [_2] for this ticket.",
                         $principal->Object->Name,
                         $self->loc($args{'Type'}) ) );
}





=head2 SquelchMailTo [EMAIL]

Takes an optional email address to never email about updates to this ticket.


Returns an array of the RT::Attribute objects for this ticket's 'SquelchMailTo' attributes.


=cut

sub SquelchMailTo {
    my $self = shift;
    if (@_) {
        unless ( $self->CurrentUserHasRight('ModifyTicket') ) {
            return ();
        }
    } else {
        unless ( $self->CurrentUserHasRight('ShowTicket') ) {
            return ();
        }

    }
    return $self->_SquelchMailTo(@_);
}

sub _SquelchMailTo {
    my $self = shift;
    if (@_) {
        my $attr = shift;
        $self->AddAttribute( Name => 'SquelchMailTo', Content => $attr )
            unless grep { $_->Content eq $attr }
                $self->Attributes->Named('SquelchMailTo');
    }
    my @attributes = $self->Attributes->Named('SquelchMailTo');
    return (@attributes);
}


=head2 UnsquelchMailTo ADDRESS

Takes an address and removes it from this ticket's "SquelchMailTo" list. If an address appears multiple times, each instance is removed.

Returns a tuple of (status, message)

=cut

sub UnsquelchMailTo {
    my $self = shift;

    my $address = shift;
    unless ( $self->CurrentUserHasRight('ModifyTicket') ) {
        return ( 0, $self->loc("Permission Denied") );
    }

    my ($val, $msg) = $self->Attributes->DeleteEntry ( Name => 'SquelchMailTo', Content => $address);
    return ($val, $msg);
}



=head2 RequestorAddresses

 B<Returns> String: All Ticket Requestor email addresses as a string.

=cut

sub RequestorAddresses {
    my $self = shift;

    unless ( $self->CurrentUserHasRight('ShowTicket') ) {
        return undef;
    }

    return ( $self->Requestors->MemberEmailAddressesAsString );
}


=head2 AdminCcAddresses

returns String: All Ticket AdminCc email addresses as a string

=cut

sub AdminCcAddresses {
    my $self = shift;

    unless ( $self->CurrentUserHasRight('ShowTicket') ) {
        return undef;
    }

    return ( $self->AdminCc->MemberEmailAddressesAsString )

}

=head2 CcAddresses

returns String: All Ticket Ccs as a string of email addresses

=cut

sub CcAddresses {
    my $self = shift;

    unless ( $self->CurrentUserHasRight('ShowTicket') ) {
        return undef;
    }
    return ( $self->Cc->MemberEmailAddressesAsString);

}




=head2 Requestors

Takes nothing.
Returns this ticket's Requestors as an RT::Group object

=cut

sub Requestors {
    my $self = shift;
    return RT::Group->new($self->CurrentUser)
        unless $self->CurrentUserHasRight('ShowTicket');
    return $self->RoleGroup( 'Requestor' );
}



=head2 Cc

Takes nothing.
Returns an RT::Group object which contains this ticket's Ccs.
If the user doesn't have "ShowTicket" permission, returns an empty group

=cut

sub Cc {
    my $self = shift;

    return RT::Group->new($self->CurrentUser)
        unless $self->CurrentUserHasRight('ShowTicket');
    return $self->RoleGroup( 'Cc' );
}



=head2 AdminCc

Takes nothing.
Returns an RT::Group object which contains this ticket's AdminCcs.
If the user doesn't have "ShowTicket" permission, returns an empty group

=cut

sub AdminCc {
    my $self = shift;

    return RT::Group->new($self->CurrentUser)
        unless $self->CurrentUserHasRight('ShowTicket');
    return $self->RoleGroup( 'AdminCc' );
}




# a generic routine to be called by IsRequestor, IsCc and IsAdminCc

=head2 IsWatcher { Type => TYPE, PrincipalId => PRINCIPAL_ID, Email => EMAIL }

Takes a param hash with the attributes Type and either PrincipalId or Email

Type is one of Requestor, Cc, AdminCc and Owner

PrincipalId is an RT::Principal id, and Email is an email address.

Returns true if the specified principal (or the one corresponding to the
specified address) is a member of the group Type for this ticket.

XX TODO: This should be Memoized. 

=cut

sub IsWatcher {
    my $self = shift;

    my %args = ( Type  => 'Requestor',
        PrincipalId    => undef,
        Email          => undef,
        @_
    );

    # Load the relevant group.
    my $group = $self->RoleGroup( $args{'Type'} );

    # Find the relevant principal.
    if (!$args{PrincipalId} && $args{Email}) {
        # Look up the specified user.
        my $user = RT::User->new($self->CurrentUser);
        $user->LoadByEmail($args{Email});
        if ($user->Id) {
            $args{PrincipalId} = $user->PrincipalId;
        }
        else {
            # A non-existent user can't be a group member.
            return 0;
        }
    }

    # Ask if it has the member in question
    return $group->HasMember( $args{'PrincipalId'} );
}



=head2 IsRequestor PRINCIPAL_ID
  
Takes an L<RT::Principal> id.

Returns true if the principal is a requestor of the current ticket.

=cut

sub IsRequestor {
    my $self   = shift;
    my $person = shift;

    return ( $self->IsWatcher( Type => 'Requestor', PrincipalId => $person ) );

};



=head2 IsCc PRINCIPAL_ID

  Takes an RT::Principal id.
  Returns true if the principal is a Cc of the current ticket.


=cut

sub IsCc {
    my $self = shift;
    my $cc   = shift;

    return ( $self->IsWatcher( Type => 'Cc', PrincipalId => $cc ) );

}



=head2 IsAdminCc PRINCIPAL_ID

  Takes an RT::Principal id.
  Returns true if the principal is an AdminCc of the current ticket.

=cut

sub IsAdminCc {
    my $self   = shift;
    my $person = shift;

    return ( $self->IsWatcher( Type => 'AdminCc', PrincipalId => $person ) );

}



=head2 IsOwner

  Takes an RT::User object. Returns true if that user is this ticket's owner.
returns undef otherwise

=cut

sub IsOwner {
    my $self   = shift;
    my $person = shift;

    # no ACL check since this is used in acl decisions
    # unless ($self->CurrentUserHasRight('ShowTicket')) {
    #    return(undef);
    #   }    

    #Tickets won't yet have owners when they're being created.
    unless ( $self->OwnerObj->id ) {
        return (undef);
    }

    if ( $person->id == $self->OwnerObj->id ) {
        return (1);
    }
    else {
        return (undef);
    }
}





=head2 TransactionAddresses

Returns a composite hashref of the results of L<RT::Transaction/Addresses> for
all this ticket's Create, Comment or Correspond transactions. The keys are
stringified email addresses. Each value is an L<Email::Address> object.

NOTE: For performance reasons, this method might want to skip transactions and go straight for attachments. But to make that work right, we're going to need to go and walk around the access control in Attachment.pm's sub _Value.

=cut


sub TransactionAddresses {
    my $self = shift;
    my $txns = $self->Transactions;

    my %addresses = ();

    my $attachments = RT::Attachments->new( $self->CurrentUser );
    $attachments->LimitByTicket( $self->id );
    $attachments->Columns( qw( id Headers TransactionId));


    foreach my $type (qw(Create Comment Correspond)) {
        $attachments->Limit( ALIAS    => $attachments->TransactionAlias,
                             FIELD    => 'Type',
                             OPERATOR => '=',
                             VALUE    => $type,
                             ENTRYAGGREGATOR => 'OR',
                             CASESENSITIVE   => 1
                           );
    }

    while ( my $att = $attachments->Next ) {
        foreach my $addrlist ( values %{$att->Addresses } ) {
            foreach my $addr (@$addrlist) {

# Skip addresses without a phrase (things that are just raw addresses) if we have a phrase
                next
                    if (    $addresses{ $addr->address }
                         && $addresses{ $addr->address }->phrase
                         && not $addr->phrase );

                # skips "comment-only" addresses
                next unless ( $addr->address );
                $addresses{ $addr->address } = $addr;
            }
        }
    }

    return \%addresses;

}






sub ValidateQueue {
    my $self  = shift;
    my $Value = shift;

    if ( !$Value ) {
        $RT::Logger->warning( " RT:::Queue::ValidateQueue called with a null value. this isn't ok.");
        return (1);
    }

    my $QueueObj = RT::Queue->new( $self->CurrentUser );
    my $id       = $QueueObj->Load($Value);

    if ($id) {
        return (1);
    }
    else {
        return (undef);
    }
}



sub SetQueue {
    my $self     = shift;
    my $NewQueue = shift;

    #Redundant. ACL gets checked in _Set;
    unless ( $self->CurrentUserHasRight('ModifyTicket') ) {
        return ( 0, $self->loc("Permission Denied") );
    }

    my $NewQueueObj = RT::Queue->new( $self->CurrentUser );
    $NewQueueObj->Load($NewQueue);

    unless ( $NewQueueObj->Id() ) {
        return ( 0, $self->loc("That queue does not exist") );
    }

    if ( $NewQueueObj->Id == $self->QueueObj->Id ) {
        return ( 0, $self->loc('That is the same value') );
    }
    unless ( $self->CurrentUser->HasRight( Right    => 'CreateTicket', Object => $NewQueueObj)
         and $NewQueueObj->Disabled != 1) {
        return ( 0, $self->loc("You may not create requests in that queue.") );
    }

    my $new_status;
    my $old_lifecycle = $self->LifecycleObj;
    my $new_lifecycle = $NewQueueObj->LifecycleObj;
    if ( $old_lifecycle->Name ne $new_lifecycle->Name ) {
        unless ( $old_lifecycle->HasMoveMap( $new_lifecycle ) ) {
            return ( 0, $self->loc("There is no mapping for statuses between these queues. Contact your system administrator.") );
        }
        $new_status = $old_lifecycle->MoveMap( $new_lifecycle )->{ $self->Status };
        return ( 0, $self->loc("Mapping between queues' lifecycles is incomplete. Contact your system administrator.") )
            unless $new_status;
    }

    my ($status, $msg) = $self->_Set( Field => 'Queue', Value => $NewQueueObj->Id() );

    if ( $status ) {
        # Clear the queue object cache;
        $self->{_queue_obj} = undef;

        if ( $new_status ) {
            my $clone = RT::Ticket->new( RT->SystemUser );
            $clone->Load( $self->Id );
            unless ( $clone->Id ) {
                return ( 0, $self->loc("Couldn't load copy of ticket #[_1].", $self->Id) );
            }

            my ($val, $msg) = $clone->_SetStatus(
                Lifecycle         => $old_lifecycle,
                NewLifecycle      => $new_lifecycle,
                Status            => $new_status,
                RecordTransaction => 0,
            );
            RT->Logger->error("Status change failed on queue change: $msg")
                unless $val;
        }

        # Untake the ticket if we have no permissions in the new queue
        unless ( $self->OwnerObj->HasRight( Right => 'OwnTicket', Object => $NewQueueObj ) ) {
            my $clone = RT::Ticket->new( RT->SystemUser );
            $clone->Load( $self->Id );
            unless ( $clone->Id ) {
                return ( 0, $self->loc("Couldn't load copy of ticket #[_1].", $self->Id) );
            }
            my ($status, $msg) = $clone->SetOwner( RT->Nobody->Id, 'Force' );
            $RT::Logger->error("Couldn't set owner on queue change: $msg") unless $status;
        }

        # On queue change, change queue for reminders too
        my $reminder_collection = $self->Reminders->Collection;
        while ( my $reminder = $reminder_collection->Next ) {
            my ($status, $msg) = $reminder->_Set( Field => 'Queue', Value => $NewQueueObj->Id(), RecordTransaction => 0 );
            $RT::Logger->error('Queue change failed for reminder #' . $reminder->Id . ': ' . $msg) unless $status;
        }

        # Pick up any changes made by the clones above
        $self->Load( $self->id );
        RT->Logger->error("Unable to reload ticket #" . $self->id)
            unless $self->id;
    }

    return ($status, $msg);
}



=head2 QueueObj

Takes nothing. returns this ticket's queue object

=cut

sub QueueObj {
    my $self = shift;

    if(!$self->{_queue_obj} || ! $self->{_queue_obj}->id) {

        $self->{_queue_obj} = RT::Queue->new( $self->CurrentUser );

        #We call __Value so that we can avoid the ACL decision and some deep recursion
        my ($result) = $self->{_queue_obj}->Load( $self->__Value('Queue') );
    }
    return ($self->{_queue_obj});
}

=head2 SubjectTag

Takes nothing. Returns SubjectTag for this ticket. Includes
queue's subject tag or rtname if that is not set, ticket
id and brackets, for example:

    [support.example.com #123456]

=cut

sub SubjectTag {
    my $self = shift;
    return
        '['
        . ($self->QueueObj->SubjectTag || RT->Config->Get('rtname'))
        .' #'. $self->id
        .']'
    ;
}


=head2 DueObj

  Returns an RT::Date object containing this ticket's due date

=cut

sub DueObj {
    my $self = shift;

    my $time = RT::Date->new( $self->CurrentUser );

    # -1 is RT::Date slang for never
    if ( my $due = $self->Due ) {
        $time->Set( Format => 'sql', Value => $due );
    }
    else {
        $time->Set( Format => 'unix', Value => -1 );
    }

    return $time;
}



=head2 DueAsString

Returns this ticket's due date as a human readable string.

B<DEPRECATED> and will be removed in 4.4; use C<<
$ticket->DueObj->AsString >> instead.

=cut

sub DueAsString {
    my $self = shift;
    $RT::Logger->warning("RT::Ticket->DueAsString is deprecated and will be removed in RT 4.4; use ->DueObj->AsString instead");
    return $self->DueObj->AsString();
}



=head2 ResolvedObj

  Returns an RT::Date object of this ticket's 'resolved' time.

=cut

sub ResolvedObj {
    my $self = shift;

    my $time = RT::Date->new( $self->CurrentUser );
    $time->Set( Format => 'sql', Value => $self->Resolved );
    return $time;
}

=head2 Lifecycle

Returns the L<RT::Lifecycle/Name> for this ticket.

=cut

sub Lifecycle {
    return shift->LifecycleObj->Name;
}

=head2 LifecycleObj

Returns the L<RT::Lifecycle> for this ticket, which is picked up from
the ticket's current queue.

=cut

sub LifecycleObj {
    my $self = shift;
    return $self->QueueObj->LifecycleObj;
}

=head2 FirstActiveStatus

Returns the first active status that the ticket could transition to,
according to its current Queue's lifecycle.  May return undef if there
is no such possible status to transition to, or we are already in it.
This is used in L<RT::Action::AutoOpen>, for instance.

=cut

sub FirstActiveStatus {
    my $self = shift;

    my $lifecycle = $self->LifecycleObj;
    my $status = $self->Status;
    my @active = $lifecycle->Active;
    # no change if no active statuses in the lifecycle
    return undef unless @active;

    # no change if the ticket is already has first status from the list of active
    return undef if lc $status eq lc $active[0];

    my ($next) = grep $lifecycle->IsActive($_), $lifecycle->Transitions($status);
    return $next;
}

=head2 FirstInactiveStatus

Returns the first inactive status that the ticket could transition to,
according to its current Queue's lifecycle.  May return undef if there
is no such possible status to transition to, or we are already in it.
This is used in resolve action in UnsafeEmailCommands, for instance.

=cut

sub FirstInactiveStatus {
    my $self = shift;

    my $lifecycle = $self->LifecycleObj;
    my $status = $self->Status;
    my @inactive = $lifecycle->Inactive;
    # no change if no inactive statuses in the lifecycle
    return undef unless @inactive;

    # no change if the ticket is already has first status from the list of inactive
    return undef if lc $status eq lc $inactive[0];

    my ($next) = grep $lifecycle->IsInactive($_), $lifecycle->Transitions($status);
    return $next;
}

=head2 SetStarted

Takes a date in ISO format or undef
Returns a transaction id and a message
The client calls "Start" to note that the project was started on the date in $date.
A null date means "now"

=cut

sub SetStarted {
    my $self = shift;
    my $time = shift || 0;

    unless ( $self->CurrentUserHasRight('ModifyTicket') ) {
        return ( 0, $self->loc("Permission Denied") );
    }

    #We create a date object to catch date weirdness
    my $time_obj = RT::Date->new( $self->CurrentUser() );
    if ( $time ) {
        $time_obj->Set( Format => 'ISO', Value => $time );
    }
    else {
        $time_obj->SetToNow();
    }

    # We need $TicketAsSystem, in case the current user doesn't have
    # ShowTicket
    my $TicketAsSystem = RT::Ticket->new(RT->SystemUser);
    $TicketAsSystem->Load( $self->Id );
    # Now that we're starting, open this ticket
    # TODO: do we really want to force this as policy? it should be a scrip
    my $next = $TicketAsSystem->FirstActiveStatus;

    $self->SetStatus( $next ) if defined $next;

    return ( $self->_Set( Field => 'Started', Value => $time_obj->ISO ) );

}



=head2 StartedObj

  Returns an RT::Date object which contains this ticket's 
'Started' time.

=cut

sub StartedObj {
    my $self = shift;

    my $time = RT::Date->new( $self->CurrentUser );
    $time->Set( Format => 'sql', Value => $self->Started );
    return $time;
}



=head2 StartsObj

  Returns an RT::Date object which contains this ticket's 
'Starts' time.

=cut

sub StartsObj {
    my $self = shift;

    my $time = RT::Date->new( $self->CurrentUser );
    $time->Set( Format => 'sql', Value => $self->Starts );
    return $time;
}



=head2 ToldObj

  Returns an RT::Date object which contains this ticket's 
'Told' time.

=cut

sub ToldObj {
    my $self = shift;

    my $time = RT::Date->new( $self->CurrentUser );
    $time->Set( Format => 'sql', Value => $self->Told );
    return $time;
}



=head2 ToldAsString

A convenience method that returns ToldObj->AsString

B<DEPRECATED> and will be removed in 4.4; use C<<
$ticket->ToldObj->AsString >> instead.

=cut

sub ToldAsString {
    my $self = shift;
    $RT::Logger->warning("RT::Ticket->ToldAsString is deprecated and will be removed in RT 4.4; use ->ToldObj->AsString instead");
    if ( $self->Told ) {
        return $self->ToldObj->AsString();
    }
    else {
        return ("Never");
    }
}



sub _DurationAsString {
    my $self = shift;
    my $value = shift;
    return "" unless $value;
    return RT::Date->new( $self->CurrentUser )
        ->DurationAsString( $value * 60 );
}

=head2 TimeWorkedAsString

Returns the amount of time worked on this ticket as a text string.

=cut

sub TimeWorkedAsString {
    my $self = shift;
    return $self->_DurationAsString( $self->TimeWorked );
}

=head2  TimeLeftAsString

Returns the amount of time left on this ticket as a text string.

=cut

sub TimeLeftAsString {
    my $self = shift;
    return $self->_DurationAsString( $self->TimeLeft );
}

=head2  TimeEstimatedAsString

Returns the amount of time estimated on this ticket as a text string.

=cut

sub TimeEstimatedAsString {
    my $self = shift;
    return $self->_DurationAsString( $self->TimeEstimated );
}




=head2 Comment

Comment on this ticket.
Takes a hash with the following attributes:
If MIMEObj is undefined, Content will be used to build a MIME::Entity for this
comment.

MIMEObj, TimeTaken, CcMessageTo, BccMessageTo, Content, DryRun

If DryRun is defined, this update WILL NOT BE RECORDED. Scrips will not be committed.
They will, however, be prepared and you'll be able to access them through the TransactionObj

Returns: Transaction id, Error Message, Transaction Object
(note the different order from Create()!)

=cut

sub Comment {
    my $self = shift;

    my %args = ( CcMessageTo  => undef,
                 BccMessageTo => undef,
                 MIMEObj      => undef,
                 Content      => undef,
                 TimeTaken => 0,
                 DryRun     => 0, 
                 @_ );

    unless (    ( $self->CurrentUserHasRight('CommentOnTicket') )
             or ( $self->CurrentUserHasRight('ModifyTicket') ) ) {
        return ( 0, $self->loc("Permission Denied"), undef );
    }
    $args{'NoteType'} = 'Comment';

    $RT::Handle->BeginTransaction();
    if ($args{'DryRun'}) {
        $args{'CommitScrips'} = 0;
    }

    my @results = $self->_RecordNote(%args);
    if ($args{'DryRun'}) {
        $RT::Handle->Rollback();
    } else {
        $RT::Handle->Commit();
    }

    return(@results);
}


=head2 Correspond

Correspond on this ticket.
Takes a hashref with the following attributes:


MIMEObj, TimeTaken, CcMessageTo, BccMessageTo, Content, DryRun

if there's no MIMEObj, Content is used to build a MIME::Entity object

If DryRun is defined, this update WILL NOT BE RECORDED. Scrips will not be committed.
They will, however, be prepared and you'll be able to access them through the TransactionObj

Returns: Transaction id, Error Message, Transaction Object
(note the different order from Create()!)


=cut

sub Correspond {
    my $self = shift;
    my %args = ( CcMessageTo  => undef,
                 BccMessageTo => undef,
                 MIMEObj      => undef,
                 Content      => undef,
                 TimeTaken    => 0,
                 @_ );

    unless (    ( $self->CurrentUserHasRight('ReplyToTicket') )
             or ( $self->CurrentUserHasRight('ModifyTicket') ) ) {
        return ( 0, $self->loc("Permission Denied"), undef );
    }
    $args{'NoteType'} = 'Correspond';

    $RT::Handle->BeginTransaction();
    if ($args{'DryRun'}) {
        $args{'CommitScrips'} = 0;
    }

    my @results = $self->_RecordNote(%args);

    #Set the last told date to now if this isn't mail from the requestor.
    #TODO: Note that this will wrongly ack mail from any non-requestor as a "told"
    unless ( $self->IsRequestor($self->CurrentUser->id) ) {
        my %squelch;
        $squelch{$_}++ for map {$_->Content} $self->SquelchMailTo, $results[2]->SquelchMailTo;
        $self->_SetTold
            if grep {not $squelch{$_}} $self->Requestors->MemberEmailAddresses;
    }

    if ($args{'DryRun'}) {
        $RT::Handle->Rollback();
    } else {
        $RT::Handle->Commit();
    }

    return (@results);

}



=head2 _RecordNote

the meat of both comment and correspond. 

Performs no access control checks. hence, dangerous.

=cut

sub _RecordNote {
    my $self = shift;
    my %args = ( 
        CcMessageTo  => undef,
        BccMessageTo => undef,
        Encrypt      => undef,
        Sign         => undef,
        MIMEObj      => undef,
        Content      => undef,
        NoteType     => 'Correspond',
        TimeTaken    => 0,
        CommitScrips => 1,
        SquelchMailTo => undef,
        @_
    );

    unless ( $args{'MIMEObj'} || $args{'Content'} ) {
        return ( 0, $self->loc("No message attached"), undef );
    }

    unless ( $args{'MIMEObj'} ) {
        $args{'MIMEObj'} = MIME::Entity->build(
            Data => ( ref $args{'Content'}? $args{'Content'}: [ $args{'Content'} ] )
        );
    }

    $args{'MIMEObj'}->head->replace('X-RT-Interface' => 'API')
        unless $args{'MIMEObj'}->head->get('X-RT-Interface');

    # convert text parts into utf-8
    RT::I18N::SetMIMEEntityToUTF8( $args{'MIMEObj'} );

    # If we've been passed in CcMessageTo and BccMessageTo fields,
    # add them to the mime object for passing on to the transaction handler
    # The "NotifyOtherRecipients" scripAction will look for RT-Send-Cc: and
    # RT-Send-Bcc: headers


    foreach my $type (qw/Cc Bcc/) {
        if ( defined $args{ $type . 'MessageTo' } ) {

            my $addresses = join ', ', (
                map { RT::User->CanonicalizeEmailAddress( $_->address ) }
                    Email::Address->parse( $args{ $type . 'MessageTo' } ) );
            $args{'MIMEObj'}->head->replace( 'RT-Send-' . $type, Encode::encode_utf8( $addresses ) );
        }
    }

    foreach my $argument (qw(Encrypt Sign)) {
        $args{'MIMEObj'}->head->replace(
            "X-RT-$argument" => Encode::encode_utf8( $args{ $argument } )
        ) if defined $args{ $argument };
    }

    # If this is from an external source, we need to come up with its
    # internal Message-ID now, so all emails sent because of this
    # message have a common Message-ID
    my $org = RT->Config->Get('Organization');
    my $msgid = $args{'MIMEObj'}->head->get('Message-ID');
    unless (defined $msgid && $msgid =~ /<(rt-.*?-\d+-\d+)\.(\d+-0-0)\@\Q$org\E>/) {
        $args{'MIMEObj'}->head->set(
            'RT-Message-ID' => Encode::encode_utf8(
                RT::Interface::Email::GenMessageId( Ticket => $self )
            )
        );
    }

    #Record the correspondence (write the transaction)
    my ( $Trans, $msg, $TransObj ) = $self->_NewTransaction(
             Type => $args{'NoteType'},
             Data => ( $args{'MIMEObj'}->head->get('subject') || 'No Subject' ),
             TimeTaken => $args{'TimeTaken'},
             MIMEObj   => $args{'MIMEObj'}, 
             CommitScrips => $args{'CommitScrips'},
             SquelchMailTo => $args{'SquelchMailTo'},
    );

    unless ($Trans) {
        $RT::Logger->err("$self couldn't init a transaction $msg");
        return ( $Trans, $self->loc("Message could not be recorded"), undef );
    }

    return ( $Trans, $self->loc("Message recorded"), $TransObj );
}


=head2 DryRun

Builds a MIME object from the given C<UpdateSubject> and
C<UpdateContent>, then calls L</Comment> or L</Correspond> with
C<< DryRun => 1 >>, and returns the transaction so produced.

=cut

sub DryRun {
    my $self = shift;
    my %args = @_;
    my $action;
    if (($args{'UpdateType'} || $args{Action}) =~ /^respon(d|se)$/i ) {
        $action = 'Correspond';
    } else {
        $action = 'Comment';
    }

    my $Message = MIME::Entity->build(
        Type    => 'text/plain',
        Subject => defined $args{UpdateSubject} ? Encode::encode_utf8( $args{UpdateSubject} ) : "",
        Charset => 'UTF-8',
        Data    => $args{'UpdateContent'} || "",
    );

    my ( $Transaction, $Description, $Object ) = $self->$action(
        CcMessageTo  => $args{'UpdateCc'},
        BccMessageTo => $args{'UpdateBcc'},
        MIMEObj      => $Message,
        TimeTaken    => $args{'UpdateTimeWorked'},
        DryRun       => 1,
    );
    unless ( $Transaction ) {
        $RT::Logger->error("Couldn't fire '$action' action: $Description");
    }

    return $Object;
}

=head2 DryRunCreate

Prepares a MIME mesage with the given C<Subject>, C<Cc>, and
C<Content>, then calls L</Create> with C<< DryRun => 1 >> and returns
the resulting L<RT::Transaction>.

=cut

sub DryRunCreate {
    my $self = shift;
    my %args = @_;
    my $Message = MIME::Entity->build(
        Type    => 'text/plain',
        Subject => defined $args{Subject} ? Encode::encode_utf8( $args{'Subject'} ) : "",
        (defined $args{'Cc'} ?
             ( Cc => Encode::encode_utf8( $args{'Cc'} ) ) : ()),
        Charset => 'UTF-8',
        Data    => $args{'Content'} || "",
    );

    my ( $Transaction, $Object, $Description ) = $self->Create(
        Type            => $args{'Type'} || 'ticket',
        Queue           => $args{'Queue'},
        Owner           => $args{'Owner'},
        Requestor       => $args{'Requestors'},
        Cc              => $args{'Cc'},
        AdminCc         => $args{'AdminCc'},
        InitialPriority => $args{'InitialPriority'},
        FinalPriority   => $args{'FinalPriority'},
        TimeLeft        => $args{'TimeLeft'},
        TimeEstimated   => $args{'TimeEstimated'},
        TimeWorked      => $args{'TimeWorked'},
        Subject         => $args{'Subject'},
        Status          => $args{'Status'},
        MIMEObj         => $Message,
        DryRun          => 1,
    );
    unless ( $Transaction ) {
        $RT::Logger->error("Couldn't fire Create action: $Description");
    }

    return $Object;
}



sub _Links {
    my $self = shift;

    #TODO: Field isn't the right thing here. but I ahave no idea what mnemonic ---
    #tobias meant by $f
    my $field = shift;
    my $type  = shift || "";

    my $cache_key = "$field$type";
    return $self->{ $cache_key } if $self->{ $cache_key };

    my $links = $self->{ $cache_key }
              = RT::Links->new( $self->CurrentUser );
    unless ( $self->CurrentUserHasRight('ShowTicket') ) {
        $links->Limit( FIELD => 'id', VALUE => 0, SUBCLAUSE => 'acl' );
        return $links;
    }

    # Maybe this ticket is a merge ticket
    my $limit_on = 'Local'. $field;
    # at least to myself
    $links->Limit(
        FIELD           => $limit_on,
        VALUE           => $self->id,
        ENTRYAGGREGATOR => 'OR',
    );
    $links->Limit(
        FIELD           => $limit_on,
        VALUE           => $_,
        ENTRYAGGREGATOR => 'OR',
    ) foreach $self->Merged;
    $links->Limit(
        FIELD => 'Type',
        VALUE => $type,
    ) if $type;

    return $links;
}



=head2 DeleteLink

Takes a paramhash of Type and one of Base or Target. Removes that link from this ticket.

Refer to L<RT::Record/_DeleteLink> for full documentation.  This method
implements permission checks before calling into L<RT::Record>.

=cut 

sub DeleteLink {
    my $self = shift;
    my %args = (
        Base   => undef,
        Target => undef,
        @_
    );

    unless ( $args{'Target'} || $args{'Base'} ) {
        $RT::Logger->error("Base or Target must be specified");
        return ( 0, $self->loc('Either base or target must be specified') );
    }

    #check acls
    my $right = 0;
    $right++ if $self->CurrentUserHasRight('ModifyTicket');
    if ( !$right && RT->Config->Get( 'StrictLinkACL' ) ) {
        return ( 0, $self->loc("Permission Denied") );
    }

    # If the other URI is an RT::Ticket, we want to make sure the user
    # can modify it too...
    my ($status, $msg, $other_ticket) = $self->__GetTicketFromURI( URI => $args{'Target'} || $args{'Base'} );
    return (0, $msg) unless $status;
    if ( !$other_ticket || $other_ticket->CurrentUserHasRight('ModifyTicket') ) {
        $right++;
    }
    if ( ( !RT->Config->Get( 'StrictLinkACL' ) && $right == 0 ) ||
         ( RT->Config->Get( 'StrictLinkACL' ) && $right < 2 ) )
    {
        return ( 0, $self->loc("Permission Denied") );
    }

    return $self->_DeleteLink(%args);
}

=head2 AddLink

Takes a paramhash of Type and one of Base or Target. Adds that link to this ticket.

Refer to L<RT::Record/_AddLink> for full documentation.  This method implements
permissions and ticket validity checks before calling into L<RT::Record>.

=cut

sub AddLink {
    my $self = shift;
    my %args = ( Target       => '',
                 Base         => '',
                 Type         => '',
                 Silent       => undef,
                 SilentBase   => undef,
                 SilentTarget => undef,
                 @_ );

    unless ( $args{'Target'} || $args{'Base'} ) {
        $RT::Logger->error("Base or Target must be specified");
        return ( 0, $self->loc('Either base or target must be specified') );
    }

    my $right = 0;
    $right++ if $self->CurrentUserHasRight('ModifyTicket');
    if ( !$right && RT->Config->Get( 'StrictLinkACL' ) ) {
        return ( 0, $self->loc("Permission Denied") );
    }

    # If the other URI is an RT::Ticket, we want to make sure the user
    # can modify it too...
    my ($status, $msg, $other_ticket) = $self->__GetTicketFromURI( URI => $args{'Target'} || $args{'Base'} );
    return (0, $msg) unless $status;
    if ( !$other_ticket || $other_ticket->CurrentUserHasRight('ModifyTicket') ) {
        $right++;
    }
    if ( ( !RT->Config->Get( 'StrictLinkACL' ) && $right == 0 ) ||
         ( RT->Config->Get( 'StrictLinkACL' ) && $right < 2 ) )
    {
        return ( 0, $self->loc("Permission Denied") );
    }

    return ( 0, "Can't link to a deleted ticket" )
      if $other_ticket && $other_ticket->Status eq 'deleted';

    return $self->_AddLink(%args);
}

sub __GetTicketFromURI {
    my $self = shift;
    my %args = ( URI => '', @_ );

    # If the other URI is an RT::Ticket, we want to make sure the user
    # can modify it too...
    my $uri_obj = RT::URI->new( $self->CurrentUser );
    $uri_obj->FromURI( $args{'URI'} );

    unless ( $uri_obj->Resolver && $uri_obj->Scheme ) {
        my $msg = $self->loc( "Couldn't resolve '[_1]' into a URI.", $args{'URI'} );
        $RT::Logger->warning( $msg );
        return( 0, $msg );
    }
    my $obj = $uri_obj->Resolver->Object;
    unless ( UNIVERSAL::isa($obj, 'RT::Ticket') && $obj->id ) {
        return (1, 'Found not a ticket', undef);
    }
    return (1, 'Found ticket', $obj);
}

=head2 MergeInto

MergeInto take the id of the ticket to merge this ticket into.

=cut

sub MergeInto {
    my $self      = shift;
    my $ticket_id = shift;

    unless ( $self->CurrentUserHasRight('ModifyTicket') ) {
        return ( 0, $self->loc("Permission Denied") );
    }

    # Load up the new ticket.
    my $MergeInto = RT::Ticket->new($self->CurrentUser);
    $MergeInto->Load($ticket_id);

    # make sure it exists.
    unless ( $MergeInto->Id ) {
        return ( 0, $self->loc("New ticket doesn't exist") );
    }

    # Make sure the current user can modify the new ticket.
    unless ( $MergeInto->CurrentUserHasRight('ModifyTicket') ) {
        return ( 0, $self->loc("Permission Denied") );
    }

    delete $MERGE_CACHE{'effective'}{ $self->id };
    delete @{ $MERGE_CACHE{'merged'} }{
        $ticket_id, $MergeInto->id, $self->id
    };

    $RT::Handle->BeginTransaction();

    $self->_MergeInto( $MergeInto );

    $RT::Handle->Commit();

    return ( 1, $self->loc("Merge Successful") );
}

sub _MergeInto {
    my $self      = shift;
    my $MergeInto = shift;


    # We use EffectiveId here even though it duplicates information from
    # the links table becasue of the massive performance hit we'd take
    # by trying to do a separate database query for merge info everytime 
    # loaded a ticket. 

    #update this ticket's effective id to the new ticket's id.
    my ( $id_val, $id_msg ) = $self->__Set(
        Field => 'EffectiveId',
        Value => $MergeInto->Id()
    );

    unless ($id_val) {
        $RT::Handle->Rollback();
        return ( 0, $self->loc("Merge failed. Couldn't set EffectiveId") );
    }


    my $force_status = $self->LifecycleObj->DefaultOnMerge;
    if ( $force_status && $force_status ne $self->__Value('Status') ) {
        my ( $status_val, $status_msg )
            = $self->__Set( Field => 'Status', Value => $force_status );

        unless ($status_val) {
            $RT::Handle->Rollback();
            $RT::Logger->error(
                "Couldn't set status to $force_status. RT's Database may be inconsistent."
            );
            return ( 0, $self->loc("Merge failed. Couldn't set Status") );
        }
    }

    # update all the links that point to that old ticket
    my $old_links_to = RT::Links->new($self->CurrentUser);
    $old_links_to->Limit(FIELD => 'Target', VALUE => $self->URI);

    my %old_seen;
    while (my $link = $old_links_to->Next) {
        if (exists $old_seen{$link->Base."-".$link->Type}) {
            $link->Delete;
        }   
        elsif ($link->Base eq $MergeInto->URI) {
            $link->Delete;
        } else {
            # First, make sure the link doesn't already exist. then move it over.
            my $tmp = RT::Link->new(RT->SystemUser);
            $tmp->LoadByCols(Base => $link->Base, Type => $link->Type, LocalTarget => $MergeInto->id);
            if ($tmp->id)   {
                    $link->Delete;
            } else { 
                $link->SetTarget($MergeInto->URI);
                $link->SetLocalTarget($MergeInto->id);
            }
            $old_seen{$link->Base."-".$link->Type} =1;
        }

    }

    my $old_links_from = RT::Links->new($self->CurrentUser);
    $old_links_from->Limit(FIELD => 'Base', VALUE => $self->URI);

    while (my $link = $old_links_from->Next) {
        if (exists $old_seen{$link->Type."-".$link->Target}) {
            $link->Delete;
        }   
        if ($link->Target eq $MergeInto->URI) {
            $link->Delete;
        } else {
            # First, make sure the link doesn't already exist. then move it over.
            my $tmp = RT::Link->new(RT->SystemUser);
            $tmp->LoadByCols(Target => $link->Target, Type => $link->Type, LocalBase => $MergeInto->id);
            if ($tmp->id)   {
                    $link->Delete;
            } else { 
                $link->SetBase($MergeInto->URI);
                $link->SetLocalBase($MergeInto->id);
                $old_seen{$link->Type."-".$link->Target} =1;
            }
        }

    }

    # Update time fields
    foreach my $type (qw(TimeEstimated TimeWorked TimeLeft)) {

        my $mutator = "Set$type";
        $MergeInto->$mutator(
            ( $MergeInto->$type() || 0 ) + ( $self->$type() || 0 ) );

    }
    # add all of this ticket's watchers to that ticket.
    for my $role ($self->Roles) {
        next if $self->RoleGroup($role)->SingleMemberRoleGroup;
        my $people = $self->RoleGroup($role)->MembersObj;
        while ( my $watcher = $people->Next ) {
            my ($val, $msg) =  $MergeInto->AddRoleMember(
                Type              => $role,
                Silent            => 1,
                PrincipalId       => $watcher->MemberId,
                InsideTransaction => 1,
            );
            unless ($val) {
                $RT::Logger->debug($msg);
            }
        }
    }

    #find all of the tickets that were merged into this ticket. 
    my $old_mergees = RT::Tickets->new( $self->CurrentUser );
    $old_mergees->Limit(
        FIELD    => 'EffectiveId',
        OPERATOR => '=',
        VALUE    => $self->Id
    );

    #   update their EffectiveId fields to the new ticket's id
    while ( my $ticket = $old_mergees->Next() ) {
        my ( $val, $msg ) = $ticket->__Set(
            Field => 'EffectiveId',
            Value => $MergeInto->Id()
        );
    }

    #make a new link: this ticket is merged into that other ticket.
    $self->AddLink( Type   => 'MergedInto', Target => $MergeInto->Id());

    $MergeInto->_SetLastUpdated;    
}

=head2 Merged

Returns list of tickets' ids that's been merged into this ticket.

=cut

sub Merged {
    my $self = shift;

    my $id = $self->id;
    return @{ $MERGE_CACHE{'merged'}{ $id } }
        if $MERGE_CACHE{'merged'}{ $id };

    my $mergees = RT::Tickets->new( $self->CurrentUser );
    $mergees->Limit(
        FIELD    => 'EffectiveId',
        VALUE    => $id,
    );
    $mergees->Limit(
        FIELD    => 'id',
        OPERATOR => '!=',
        VALUE    => $id,
    );
    return @{ $MERGE_CACHE{'merged'}{ $id } ||= [] }
        = map $_->id, @{ $mergees->ItemsArrayRef || [] };
}





=head2 OwnerObj

Takes nothing and returns an RT::User object of 
this ticket's owner

=cut

sub OwnerObj {
    my $self = shift;

    #If this gets ACLed, we lose on a rights check in User.pm and
    #get deep recursion. if we need ACLs here, we need
    #an equiv without ACLs

    my $owner = RT::User->new( $self->CurrentUser );
    $owner->Load( $self->__Value('Owner') );

    #Return the owner object
    return ($owner);
}



=head2 OwnerAsString

Returns the owner's email address

=cut

sub OwnerAsString {
    my $self = shift;
    return ( $self->OwnerObj->EmailAddress );

}



=head2 SetOwner

Takes two arguments:
     the Id or Name of the owner 
and  (optionally) the type of the SetOwner Transaction. It defaults
to 'Set'.  'Steal' is also a valid option.


=cut

sub SetOwner {
    my $self     = shift;
    my $NewOwner = shift;
    my $Type     = shift || "Set";

    $RT::Handle->BeginTransaction();

    $self->_SetLastUpdated(); # lock the ticket
    $self->Load( $self->id ); # in case $self changed while waiting for lock

    my $OldOwnerObj = $self->OwnerObj;

    my $NewOwnerObj = RT::User->new( $self->CurrentUser );
    $NewOwnerObj->Load( $NewOwner );
    unless ( $NewOwnerObj->Id ) {
        $RT::Handle->Rollback();
        return ( 0, $self->loc("That user does not exist") );
    }

    if ( !$self->_CurrentUserHasRightToSetOwner ) {
        $RT::Handle->Rollback();
        return ( 0, $self->loc("Permission Denied") );
    }

    my ( $val, $msg ) = $self->_IsProposedOwnerChangeValid( $NewOwnerObj, $Type );
    unless ($val) {
        $RT::Handle->Rollback();
        return ( $val, $msg );
    }

    ($val, $msg ) = $self->OwnerGroup->_AddMember(
        PrincipalId       => $NewOwnerObj->PrincipalId,
        InsideTransaction => 1,
        Object            => $self,
    );
    unless ($val) {
        $RT::Handle->Rollback;
        return ( 0, $self->loc("Could not change owner: [_1]", $msg) );
    }

    $msg = $self->loc( "Owner changed from [_1] to [_2]",
                       $OldOwnerObj->Name, $NewOwnerObj->Name );

    $RT::Handle->Commit();

    return ( $val, $msg );
}

sub _CurrentUserHasRightToSetOwner {
    my $self = shift;
    # must have ModifyTicket rights
    # or TakeTicket/StealTicket and $NewOwner is self
    # see if it's a take
    my $OldOwnerObj = $self->OwnerObj;
    if ( $OldOwnerObj->Id == RT->Nobody->Id ) {
        unless (    $self->CurrentUserHasRight('ModifyTicket')
                 || $self->CurrentUserHasRight('TakeTicket') ) {
            return 0;
        }
    }

    # see if it's a steal
    elsif (    $OldOwnerObj->Id != RT->Nobody->Id
            && $OldOwnerObj->Id != $self->CurrentUser->id ) {

        unless (    $self->CurrentUserHasRight('ModifyTicket')
                 || $self->CurrentUserHasRight('StealTicket') ) {
            return 0;
        }
    }
    else {
        unless ( $self->CurrentUserHasRight('ModifyTicket') ) {
            return 0;
        }
    }
    return 1;
}

sub _IsProposedOwnerChangeValid {
    my $self        = shift;
    my $NewOwnerObj = shift;
    my $Type        = shift;

    my $OldOwnerObj = $self->OwnerObj;

    # If we're not stealing and the ticket has an owner and it's not
    # the current user
    if (     $Type ne 'Steal' and $Type ne 'Force'
         and $OldOwnerObj->Id != RT->Nobody->Id
         and $OldOwnerObj->Id != $self->CurrentUser->Id ) {
        if ( $NewOwnerObj->id == $self->CurrentUser->id) {
            return ( 0, $self->loc("You can only take tickets that are unowned") )
        }
        else {
            return ( 0, $self->loc( "You can only reassign tickets that you own or that are unowned"));
        }
    }

    #If we've specified a new owner and that user can't modify the ticket
    elsif ( !$NewOwnerObj->HasRight( Right => 'OwnTicket', Object => $self ) )
    {
        return ( 0, $self->loc("That user may not own tickets in that queue") );
    }

    # If the ticket has an owner and it's the new owner, we don't need
    # To do anything
    elsif ( $NewOwnerObj->Id == $OldOwnerObj->Id ) {
        return ( 0, $self->loc("That user already owns that ticket") );
    }
    return (1, undef);
}

=head2 Take

A convenince method to set the ticket's owner to the current user

=cut

sub Take {
    my $self = shift;
    return ( $self->SetOwner( $self->CurrentUser->Id, 'Take' ) );
}



=head2 Untake

Convenience method to set the owner to 'nobody' if the current user is the owner.

=cut

sub Untake {
    my $self = shift;
    return ( $self->SetOwner( RT->Nobody->UserObj->Id, 'Untake' ) );
}



=head2 Steal

A convenience method to change the owner of the current ticket to the
current user. Even if it's owned by another user.

=cut

sub Steal {
    my $self = shift;

    if ( $self->IsOwner( $self->CurrentUser ) ) {
        return ( 0, $self->loc("You already own this ticket") );
    }
    else {
        return ( $self->SetOwner( $self->CurrentUser->Id, 'Steal' ) );

    }

}





=head2 ValidateStatus STATUS

Takes a string. Returns true if that status is a valid status for this ticket.
Returns false otherwise.

=cut

sub ValidateStatus {
    my $self   = shift;
    my $status = shift;

    #Make sure the status passed in is valid
    return 1 if $self->QueueObj->IsValidStatus($status);

    return 0;
}



=head2 SetStatus STATUS

Set this ticket's status.

Alternatively, you can pass in a list of named parameters (Status => STATUS, Force => FORCE, SetStarted => SETSTARTED ).
If FORCE is true, ignore unresolved dependencies and force a status change.
if SETSTARTED is true (it's the default value), set Started to current datetime if Started 
is not set and the status is changed from initial to not initial. 

=cut

sub SetStatus {
    my $self = shift;
    my %args;
    if (@_ == 1) {
        $args{Status} = shift;
    }
    else {
        %args = (@_);
    }

    # this only allows us to SetStarted, not we must SetStarted.
    # this option was added for rtir initially
    $args{SetStarted} = 1 unless exists $args{SetStarted};


    my $lifecycle = $self->LifecycleObj;

    my $new = $args{'Status'};
    unless ( $lifecycle->IsValid( $new ) ) {
        return (0, $self->loc("Status '[_1]' isn't a valid status for tickets in this queue.", $self->loc($new)));
    }

    my $old = $self->__Value('Status');
    unless ( $lifecycle->IsTransition( $old => $new ) ) {
        return (0, $self->loc("You can't change status from '[_1]' to '[_2]'.", $self->loc($old), $self->loc($new)));
    }

    my $check_right = $lifecycle->CheckRight( $old => $new );
    unless ( $self->CurrentUserHasRight( $check_right ) ) {
        return ( 0, $self->loc('Permission Denied') );
    }

    if (   !$args{Force}
        && !$lifecycle->IsInactive($self->Status)
        && $lifecycle->IsInactive($new)
        && $self->HasUnresolvedDependencies )
    {
        return ( 0, $self->loc('That ticket has unresolved dependencies') );
    }

    return $self->_SetStatus(
        Status     => $args{Status},
        SetStarted => $args{SetStarted},
    );
}

sub _SetStatus {
    my $self = shift;
    my %args = (
        Status => undef,
        SetStarted => 1,
        RecordTransaction => 1,
        Lifecycle => $self->LifecycleObj,
        @_,
    );
    $args{NewLifecycle} ||= $args{Lifecycle};

    my $now = RT::Date->new( $self->CurrentUser );
    $now->SetToNow();

    my $raw_started = RT::Date->new(RT->SystemUser);
    $raw_started->Set(Format => 'ISO', Value => $self->__Value('Started'));

    my $old = $self->__Value('Status');

    # If we're changing the status from new, record that we've started
    if ( $args{SetStarted}
             && $args{Lifecycle}->IsInitial($old)
             && !$args{NewLifecycle}->IsInitial($args{Status})
             && !$raw_started->Unix) {
        # Set the Started time to "now"
        $self->_Set(
            Field             => 'Started',
            Value             => $now->ISO,
            RecordTransaction => 0
        );
    }

    # When we close a ticket, set the 'Resolved' attribute to now.
    # It's misnamed, but that's just historical.
    if ( $args{NewLifecycle}->IsInactive($args{Status}) ) {
        $self->_Set(
            Field             => 'Resolved',
            Value             => $now->ISO,
            RecordTransaction => 0,
        );
    }

    # Actually update the status
    my ($val, $msg)= $self->_Set(
        Field           => 'Status',
        Value           => $args{Status},
        TimeTaken       => 0,
        CheckACL        => 0,
        TransactionType => 'Status',
        RecordTransaction => $args{RecordTransaction},
    );
    return ($val, $msg);
}



=head2 Delete

Takes no arguments. Marks this ticket for garbage collection

=cut

sub Delete {
    my $self = shift;
    unless ( $self->LifecycleObj->IsValid('deleted') ) {
        return (0, $self->loc('Delete operation is disabled by lifecycle configuration') ); #loc
    }
    return ( $self->SetStatus('deleted') );
}


=head2 SetTold ISO  [TIMETAKEN]

Updates the told and records a transaction

=cut

sub SetTold {
    my $self = shift;
    my $told;
    $told = shift if (@_);
    my $timetaken = shift || 0;

    unless ( $self->CurrentUserHasRight('ModifyTicket') ) {
        return ( 0, $self->loc("Permission Denied") );
    }

    my $datetold = RT::Date->new( $self->CurrentUser );
    if ($told) {
        $datetold->Set( Format => 'iso',
                        Value  => $told );
    }
    else {
        $datetold->SetToNow();
    }

    return ( $self->_Set( Field           => 'Told',
                          Value           => $datetold->ISO,
                          TimeTaken       => $timetaken,
                          TransactionType => 'Told' ) );
}

=head2 _SetTold

Updates the told without a transaction or acl check. Useful when we're sending replies.

=cut

sub _SetTold {
    my $self = shift;

    my $now = RT::Date->new( $self->CurrentUser );
    $now->SetToNow();

    #use __Set to get no ACLs ;)
    return ( $self->__Set( Field => 'Told',
                           Value => $now->ISO ) );
}

=head2 SeenUpTo


=cut

sub SeenUpTo {
    my $self = shift;
    my $uid = $self->CurrentUser->id;
    my $attr = $self->FirstAttribute( "User-". $uid ."-SeenUpTo" );
    return if $attr && $attr->Content gt $self->LastUpdated;

    my $txns = $self->Transactions;
    $txns->Limit( FIELD => 'Type', VALUE => 'Comment' );
    $txns->Limit( FIELD => 'Type', VALUE => 'Correspond' );
    $txns->Limit( FIELD => 'Creator', OPERATOR => '!=', VALUE => $uid );
    $txns->Limit(
        FIELD => 'Created',
        OPERATOR => '>',
        VALUE => $attr->Content
    ) if $attr;
    $txns->RowsPerPage(1);
    return $txns->First;
}

=head2 RanTransactionBatch

Acts as a guard around running TransactionBatch scrips.

Should be false until you enter the code that runs TransactionBatch scrips

Accepts an optional argument to indicate that TransactionBatch Scrips should no longer be run on this object.

=cut

sub RanTransactionBatch {
    my $self = shift;
    my $val = shift;

    if ( defined $val ) {
        return $self->{_RanTransactionBatch} = $val;
    } else {
        return $self->{_RanTransactionBatch};
    }

}


=head2 TransactionBatch

Returns an array reference of all transactions created on this ticket during
this ticket object's lifetime or since last application of a batch, or undef
if there were none.

Only works when the C<UseTransactionBatch> config option is set to true.

=cut

sub TransactionBatch {
    my $self = shift;
    return $self->{_TransactionBatch};
}

=head2 ApplyTransactionBatch

Applies scrips on the current batch of transactions and shinks it. Usually
batch is applied when object is destroyed, but in some cases it's too late.

=cut

sub ApplyTransactionBatch {
    my $self = shift;

    my $batch = $self->TransactionBatch;
    return unless $batch && @$batch;

    $self->_ApplyTransactionBatch;

    $self->{_TransactionBatch} = [];
}

sub _ApplyTransactionBatch {
    my $self = shift;

    return if $self->RanTransactionBatch;
    $self->RanTransactionBatch(1);

    my $still_exists = RT::Ticket->new( RT->SystemUser );
    $still_exists->Load( $self->Id );
    if (not $still_exists->Id) {
        # The ticket has been removed from the database, but we still
        # have pending TransactionBatch txns for it.  Unfortunately,
        # because it isn't in the DB anymore, attempting to run scrips
        # on it may produce unpredictable results; simply drop the
        # batched transactions.
        $RT::Logger->warning("TransactionBatch was fired on a ticket that no longer exists; unable to run scrips!  Call ->ApplyTransactionBatch before shredding the ticket, for consistent results.");
        return;
    }

    my $batch = $self->TransactionBatch;

    my %seen;
    my $types = join ',', grep !$seen{$_}++, grep defined, map $_->__Value('Type'), grep defined, @{$batch};

    require RT::Scrips;
    RT::Scrips->new(RT->SystemUser)->Apply(
        Stage          => 'TransactionBatch',
        TicketObj      => $self,
        TransactionObj => $batch->[0],
        Type           => $types,
    );

    # Entry point of the rule system
    my $rules = RT::Ruleset->FindAllRules(
        Stage          => 'TransactionBatch',
        TicketObj      => $self,
        TransactionObj => $batch->[0],
        Type           => $types,
    );
    RT::Ruleset->CommitRules($rules);
}

sub DESTROY {
    my $self = shift;

    # DESTROY methods need to localize $@, or it may unset it.  This
    # causes $m->abort to not bubble all of the way up.  See perlbug
    # http://rt.perl.org/rt3/Ticket/Display.html?id=17650
    local $@;

    # The following line eliminates reentrancy.
    # It protects against the fact that perl doesn't deal gracefully
    # when an object's refcount is changed in its destructor.
    return if $self->{_Destroyed}++;

    if (in_global_destruction()) {
       unless ($ENV{'HARNESS_ACTIVE'}) {
            warn "Too late to safely run transaction-batch scrips!"
                ." This is typically caused by using ticket objects"
                ." at the top-level of a script which uses the RT API."
               ." Be sure to explicitly undef such ticket objects,"
                ." or put them inside of a lexical scope.";
        }
        return;
    }

    return $self->ApplyTransactionBatch;
}




sub _OverlayAccessible {
    {
        EffectiveId       => { 'read' => 1,  'write' => 1,  'public' => 1 },
          Queue           => { 'read' => 1,  'write' => 1 },
          Requestors      => { 'read' => 1,  'write' => 1 },
          Owner           => { 'read' => 1,  'write' => 1 },
          Subject         => { 'read' => 1,  'write' => 1 },
          InitialPriority => { 'read' => 1,  'write' => 1 },
          FinalPriority   => { 'read' => 1,  'write' => 1 },
          Priority        => { 'read' => 1,  'write' => 1 },
          Status          => { 'read' => 1,  'write' => 1 },
          TimeEstimated      => { 'read' => 1,  'write' => 1 },
          TimeWorked      => { 'read' => 1,  'write' => 1 },
          TimeLeft        => { 'read' => 1,  'write' => 1 },
          Told            => { 'read' => 1,  'write' => 1 },
          Resolved        => { 'read' => 1 },
          Type            => { 'read' => 1 },
          Starts        => { 'read' => 1, 'write' => 1 },
          Started       => { 'read' => 1, 'write' => 1 },
          Due           => { 'read' => 1, 'write' => 1 },
          Creator       => { 'read' => 1, 'auto'  => 1 },
          Created       => { 'read' => 1, 'auto'  => 1 },
          LastUpdatedBy => { 'read' => 1, 'auto'  => 1 },
          LastUpdated   => { 'read' => 1, 'auto'  => 1 }
    };

}



sub _Set {
    my $self = shift;

    my %args = ( Field             => undef,
                 Value             => undef,
                 TimeTaken         => 0,
                 RecordTransaction => 1,
                 CheckACL          => 1,
                 TransactionType   => 'Set',
                 @_ );

    if ($args{'CheckACL'}) {
        unless ( $self->CurrentUserHasRight('ModifyTicket')) {
            return ( 0, $self->loc("Permission Denied"));
        }
    }

    # Avoid ACL loops using _Value
    my $Old = $self->SUPER::_Value($args{'Field'});

    # Set the new value
    my ( $ret, $msg ) = $self->SUPER::_Set(
        Field => $args{'Field'},
        Value => $args{'Value'}
    );
    return ( 0, $msg ) unless $ret;

    return ( $ret, $msg ) unless $args{'RecordTransaction'};

    my $trans;
    ( $ret, $msg, $trans ) = $self->_NewTransaction(
        Type      => $args{'TransactionType'},
        Field     => $args{'Field'},
        NewValue  => $args{'Value'},
        OldValue  => $Old,
        TimeTaken => $args{'TimeTaken'},
    );

    # Ensure that we can read the transaction, even if the change
    # just made the ticket unreadable to us
    $trans->{ _object_is_readable } = 1;

    return ( $ret, scalar $trans->BriefDescription );
}



=head2 _Value

Takes the name of a table column.
Returns its value as a string, if the user passes an ACL check

=cut

sub _Value {

    my $self  = shift;
    my $field = shift;

    #if the field is public, return it.
    if ( $self->_Accessible( $field, 'public' ) ) {

        #$RT::Logger->debug("Skipping ACL check for $field");
        return ( $self->SUPER::_Value($field) );

    }

    #If the current user doesn't have ACLs, don't let em at it.  

    unless ( $self->CurrentUserHasRight('ShowTicket') ) {
        return (undef);
    }
    return ( $self->SUPER::_Value($field) );

}

=head2 Attachments

Customization of L<RT::Record/Attachments> for tickets.

=cut

sub Attachments {
    my $self = shift;
    my %args = (
        WithHeaders => 0,
        WithContent => 0,
        @_
    );
    my $res = RT::Attachments->new( $self->CurrentUser );
    unless ( $self->CurrentUserHasRight('ShowTicket') ) {
        $res->Limit(
            SUBCLAUSE => 'acl',
            FIELD    => 'id',
            VALUE    => 0,
            ENTRYAGGREGATOR => 'AND'
        );
        return $res;
    }

    my @columns = grep { not /^(Headers|Content)$/ }
                       RT::Attachment->ReadableAttributes;
    push @columns, 'Headers' if $args{'WithHeaders'};
    push @columns, 'Content' if $args{'WithContent'};

    $res->Columns( @columns );
    my $txn_alias = $res->TransactionAlias;
    $res->Limit(
        ALIAS => $txn_alias,
        FIELD => 'ObjectType',
        VALUE => ref($self),
    );
    my $ticket_alias = $res->Join(
        ALIAS1 => $txn_alias,
        FIELD1 => 'ObjectId',
        TABLE2 => 'Tickets',
        FIELD2 => 'id',
    );
    $res->Limit(
        ALIAS => $ticket_alias,
        FIELD => 'EffectiveId',
        VALUE => $self->id,
    );
    return $res;
}

=head2 TextAttachments

Customization of L<RT::Record/TextAttachments> for tickets.

=cut

sub TextAttachments {
    my $self = shift;

    my $res = $self->SUPER::TextAttachments( @_ );
    unless ( $self->CurrentUserHasRight('ShowTicketComments') ) {
        # if the user may not see comments do not return them
        $res->Limit(
            SUBCLAUSE => 'ACL',
            ALIAS     => $res->TransactionAlias,
            FIELD     => 'Type',
            OPERATOR  => '!=',
            VALUE     => 'Comment',
        );
    }

    return $res;
}



=head2 _UpdateTimeTaken

This routine will increment the timeworked counter. it should
only be called from _NewTransaction 

=cut

sub _UpdateTimeTaken {
    my $self    = shift;
    my $Minutes = shift;
    my ($Total);

    $Total = $self->SUPER::_Value("TimeWorked");
    $Total = ( $Total || 0 ) + ( $Minutes || 0 );
    $self->SUPER::_Set(
        Field => "TimeWorked",
        Value => $Total
    );

    return ($Total);
}





=head2 CurrentUserHasRight

  Takes the textual name of a Ticket scoped right (from RT::ACE) and returns
1 if the user has that right. It returns 0 if the user doesn't have that right.

=cut

sub CurrentUserHasRight {
    my $self  = shift;
    my $right = shift;

    return $self->CurrentUser->PrincipalObj->HasRight(
        Object => $self,
        Right  => $right,
    )
}


=head2 CurrentUserCanSee

Returns true if the current user can see the ticket, using ShowTicket

=cut

sub CurrentUserCanSee {
    my $self = shift;
    return $self->CurrentUserHasRight('ShowTicket');
}

=head2 HasRight

 Takes a paramhash with the attributes 'Right' and 'Principal'
  'Right' is a ticket-scoped textual right from RT::ACE 
  'Principal' is an RT::User object

  Returns 1 if the principal has the right. Returns undef if not.

=cut

sub HasRight {
    my $self = shift;
    my %args = (
        Right     => undef,
        Principal => undef,
        @_
    );

    unless ( ( defined $args{'Principal'} ) and ( ref( $args{'Principal'} ) ) )
    {
        Carp::cluck("Principal attrib undefined for Ticket::HasRight");
        $RT::Logger->crit("Principal attrib undefined for Ticket::HasRight");
        return(undef);
    }

    return (
        $args{'Principal'}->HasRight(
            Object => $self,
            Right     => $args{'Right'}
          )
    );
}



=head2 Reminders

Return the Reminders object for this ticket. (It's an RT::Reminders object.)
It isn't acutally a searchbuilder collection itself.

=cut

sub Reminders {
    my $self = shift;
    
    unless ($self->{'__reminders'}) {
        $self->{'__reminders'} = RT::Reminders->new($self->CurrentUser);
        $self->{'__reminders'}->Ticket($self->id);
    }
    return $self->{'__reminders'};

}




=head2 Transactions

  Returns an RT::Transactions object of all transactions on this ticket

=cut

sub Transactions {
    my $self = shift;

    my $transactions = RT::Transactions->new( $self->CurrentUser );

    #If the user has no rights, return an empty object
    if ( $self->CurrentUserHasRight('ShowTicket') ) {
        $transactions->LimitToTicket($self->id);

        # if the user may not see comments do not return them
        unless ( $self->CurrentUserHasRight('ShowTicketComments') ) {
            $transactions->Limit(
                SUBCLAUSE => 'acl',
                FIELD    => 'Type',
                OPERATOR => '!=',
                VALUE    => "Comment"
            );
            $transactions->Limit(
                SUBCLAUSE => 'acl',
                FIELD    => 'Type',
                OPERATOR => '!=',
                VALUE    => "CommentEmailRecord",
                ENTRYAGGREGATOR => 'AND'
            );

        }
    } else {
        $transactions->Limit(
            SUBCLAUSE => 'acl',
            FIELD    => 'id',
            VALUE    => 0,
            ENTRYAGGREGATOR => 'AND'
        );
    }

    return ($transactions);
}




=head2 TransactionCustomFields

    Returns the custom fields that transactions on tickets will have.

=cut

sub TransactionCustomFields {
    my $self = shift;
    my $cfs = $self->QueueObj->TicketTransactionCustomFields;
    $cfs->SetContextObject( $self );
    return $cfs;
}


=head2 LoadCustomFieldByIdentifier

Finds and returns the custom field of the given name for the ticket,
overriding L<RT::Record/LoadCustomFieldByIdentifier> to look for
queue-specific CFs before global ones.

=cut

sub LoadCustomFieldByIdentifier {
    my $self  = shift;
    my $field = shift;

    return $self->SUPER::LoadCustomFieldByIdentifier($field)
        if ref $field or $field =~ /^\d+$/;

    my $cf = RT::CustomField->new( $self->CurrentUser );
    $cf->SetContextObject( $self );
    $cf->LoadByNameAndQueue( Name => $field, Queue => $self->Queue );
    $cf->LoadByNameAndQueue( Name => $field, Queue => 0 ) unless $cf->id;
    return $cf;
}


=head2 CustomFieldLookupType

Returns the RT::Ticket lookup type, which can be passed to 
RT::CustomField->Create() via the 'LookupType' hash key.

=cut


sub CustomFieldLookupType {
    "RT::Queue-RT::Ticket";
}

=head2 ACLEquivalenceObjects

This method returns a list of objects for which a user's rights also apply
to this ticket. Generally, this is only the ticket's queue, but some RT 
extensions may make other objects available too.

This method is called from L<RT::Principal/HasRight>.

=cut

sub ACLEquivalenceObjects {
    my $self = shift;
    return $self->QueueObj;

}

1;

=head1 AUTHOR

Jesse Vincent, jesse@bestpractical.com

=head1 SEE ALSO

RT

=cut


use RT::Queue;
use base 'RT::Record';

sub Table {'Tickets'}






=head2 id

Returns the current value of id.
(In the database, id is stored as int(11).)


=cut


=head2 EffectiveId

Returns the current value of EffectiveId.
(In the database, EffectiveId is stored as int(11).)



=head2 SetEffectiveId VALUE


Set EffectiveId to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, EffectiveId will be stored as a int(11).)


=cut


=head2 Queue

Returns the current value of Queue.
(In the database, Queue is stored as int(11).)



=head2 SetQueue VALUE


Set Queue to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Queue will be stored as a int(11).)


=cut


=head2 Type

Returns the current value of Type.
(In the database, Type is stored as varchar(16).)



=head2 SetType VALUE


Set Type to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Type will be stored as a varchar(16).)


=cut


=head2 IssueStatement

Returns the current value of IssueStatement.
(In the database, IssueStatement is stored as int(11).)



=head2 SetIssueStatement VALUE


Set IssueStatement to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, IssueStatement will be stored as a int(11).)


=cut


=head2 Resolution

Returns the current value of Resolution.
(In the database, Resolution is stored as int(11).)



=head2 SetResolution VALUE


Set Resolution to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Resolution will be stored as a int(11).)


=cut


=head2 Owner

Returns the current value of Owner.
(In the database, Owner is stored as int(11).)



=head2 SetOwner VALUE


Set Owner to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Owner will be stored as a int(11).)


=cut


=head2 Subject

Returns the current value of Subject.
(In the database, Subject is stored as varchar(200).)



=head2 SetSubject VALUE


Set Subject to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Subject will be stored as a varchar(200).)


=cut


=head2 InitialPriority

Returns the current value of InitialPriority.
(In the database, InitialPriority is stored as int(11).)



=head2 SetInitialPriority VALUE


Set InitialPriority to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, InitialPriority will be stored as a int(11).)


=cut


=head2 FinalPriority

Returns the current value of FinalPriority.
(In the database, FinalPriority is stored as int(11).)



=head2 SetFinalPriority VALUE


Set FinalPriority to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, FinalPriority will be stored as a int(11).)


=cut


=head2 Priority

Returns the current value of Priority.
(In the database, Priority is stored as int(11).)



=head2 SetPriority VALUE


Set Priority to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Priority will be stored as a int(11).)


=cut


=head2 TimeEstimated

Returns the current value of TimeEstimated.
(In the database, TimeEstimated is stored as int(11).)



=head2 SetTimeEstimated VALUE


Set TimeEstimated to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, TimeEstimated will be stored as a int(11).)


=cut


=head2 TimeWorked

Returns the current value of TimeWorked.
(In the database, TimeWorked is stored as int(11).)



=head2 SetTimeWorked VALUE


Set TimeWorked to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, TimeWorked will be stored as a int(11).)


=cut


=head2 Status

Returns the current value of Status.
(In the database, Status is stored as varchar(64).)



=head2 SetStatus VALUE


Set Status to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Status will be stored as a varchar(64).)


=cut


=head2 TimeLeft

Returns the current value of TimeLeft.
(In the database, TimeLeft is stored as int(11).)



=head2 SetTimeLeft VALUE


Set TimeLeft to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, TimeLeft will be stored as a int(11).)


=cut


=head2 Told

Returns the current value of Told.
(In the database, Told is stored as datetime.)



=head2 SetTold VALUE


Set Told to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Told will be stored as a datetime.)


=cut


=head2 Starts

Returns the current value of Starts.
(In the database, Starts is stored as datetime.)



=head2 SetStarts VALUE


Set Starts to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Starts will be stored as a datetime.)


=cut


=head2 Started

Returns the current value of Started.
(In the database, Started is stored as datetime.)



=head2 SetStarted VALUE


Set Started to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Started will be stored as a datetime.)


=cut


=head2 Due

Returns the current value of Due.
(In the database, Due is stored as datetime.)



=head2 SetDue VALUE


Set Due to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Due will be stored as a datetime.)


=cut


=head2 Resolved

Returns the current value of Resolved.
(In the database, Resolved is stored as datetime.)



=head2 SetResolved VALUE


Set Resolved to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Resolved will be stored as a datetime.)


=cut


=head2 LastUpdatedBy

Returns the current value of LastUpdatedBy.
(In the database, LastUpdatedBy is stored as int(11).)


=cut


=head2 LastUpdated

Returns the current value of LastUpdated.
(In the database, LastUpdated is stored as datetime.)


=cut


=head2 Creator

Returns the current value of Creator.
(In the database, Creator is stored as int(11).)


=cut


=head2 Created

Returns the current value of Created.
(In the database, Created is stored as datetime.)


=cut


=head2 Disabled

Returns the current value of Disabled.
(In the database, Disabled is stored as smallint(6).)



=head2 SetDisabled VALUE


Set Disabled to VALUE.
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, Disabled will be stored as a smallint(6).)


=cut



sub _CoreAccessible {
    {

        id =>
		{read => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => ''},
        EffectiveId =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        Queue =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        Type =>
		{read => 1, write => 1, sql_type => 12, length => 16,  is_blob => 0,  is_numeric => 0,  type => 'varchar(16)', default => ''},
        IssueStatement =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        Resolution =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        Owner =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        Subject =>
		{read => 1, write => 1, sql_type => 12, length => 200,  is_blob => 0,  is_numeric => 0,  type => 'varchar(200)', default => '[no subject]'},
        InitialPriority =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        FinalPriority =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        Priority =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        TimeEstimated =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        TimeWorked =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        Status =>
		{read => 1, write => 1, sql_type => 12, length => 64,  is_blob => 0,  is_numeric => 0,  type => 'varchar(64)', default => ''},
        TimeLeft =>
		{read => 1, write => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        Told =>
		{read => 1, write => 1, sql_type => 11, length => 0,  is_blob => 0,  is_numeric => 0,  type => 'datetime', default => ''},
        Starts =>
		{read => 1, write => 1, sql_type => 11, length => 0,  is_blob => 0,  is_numeric => 0,  type => 'datetime', default => ''},
        Started =>
		{read => 1, write => 1, sql_type => 11, length => 0,  is_blob => 0,  is_numeric => 0,  type => 'datetime', default => ''},
        Due =>
		{read => 1, write => 1, sql_type => 11, length => 0,  is_blob => 0,  is_numeric => 0,  type => 'datetime', default => ''},
        Resolved =>
		{read => 1, write => 1, sql_type => 11, length => 0,  is_blob => 0,  is_numeric => 0,  type => 'datetime', default => ''},
        LastUpdatedBy =>
		{read => 1, auto => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        LastUpdated =>
		{read => 1, auto => 1, sql_type => 11, length => 0,  is_blob => 0,  is_numeric => 0,  type => 'datetime', default => ''},
        Creator =>
		{read => 1, auto => 1, sql_type => 4, length => 11,  is_blob => 0,  is_numeric => 1,  type => 'int(11)', default => '0'},
        Created =>
		{read => 1, auto => 1, sql_type => 11, length => 0,  is_blob => 0,  is_numeric => 0,  type => 'datetime', default => ''},
        Disabled =>
		{read => 1, write => 1, sql_type => 5, length => 6,  is_blob => 0,  is_numeric => 1,  type => 'smallint(6)', default => '0'},

 }
};

RT::Base->_ImportOverlays();

1;
