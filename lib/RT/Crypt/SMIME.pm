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

use strict;
use warnings;

package RT::Crypt::SMIME;
use base 'RT::Crypt::Base';

use RT::Crypt;
use IPC::Run3 0.036 'run3';
use String::ShellQuote 'shell_quote';
use RT::Util 'safe_run_child';

=head1 NAME

RT::Crypt::SMIME - encrypt/decrypt and sign/verify email messages with the SMIME

=head1 CONFIGURATION

You should start from reading L<RT::Crypt>.

=head2 %SMIME

    Set( %SMIME,
        Enable => 1,
        OpenSSL => '/usr/bin/openssl',
        Keyring => '/opt/rt4/var/data/smime',
        Passphrase => {
            'queue.address@exampl.com' => 'passphrase',
        },
    );

=head3 OpenSSL

Path to openssl executable.

=head3 Keyring

Path to directory with keys and certificates for queues. Key and certificates
should be stored in a PEM file named F<email.address@example.com.pem>.

=head3 Passphrase

Either scalar with one passphrase for all keys or hash with address
and passphrase pairs for keys in the keyring.

=cut

{ my $cache = '';
sub OpenSSLPath {
    return $cache ||= RT->Config->Get('SMIME')->{'OpenSSL'} || 'openssl';
} }

sub SignEncrypt {
    my $self = shift;
    my %args = (
        Entity => undef,

        Sign => 1,
        Signer => undef,
        Passphrase => undef,

        Encrypt => 1,
        Recipients => undef,

        @_
    );

    my $entity = $args{'Entity'};

    if ( $args{'Encrypt'} ) {
        my %seen;
        $args{'Recipients'} = [
            grep !$seen{$_}++, map $_->address, map Email::Address->parse($_),
            grep defined && length, map $entity->head->get($_), qw(To Cc Bcc)
        ];
    }

    $entity->make_multipart('mixed', Force => 1);
    my ($buf, %res) = $self->_SignEncrypt(
        %args,
        Content => \$entity->parts(0)->stringify,
    );
    unless ( $buf ) {
        $entity->make_singlepart;
        return %res;
    }

    my $tmpdir = File::Temp::tempdir( TMPDIR => 1, CLEANUP => 1 );
    my $parser = MIME::Parser->new();
    $parser->output_dir($tmpdir);
    my $newmime = $parser->parse_data($$buf);

    $entity->parts([$newmime]);
    $entity->make_singlepart;

    return %res;
}

sub SignEncryptContent {
    my $self = shift;
    my %args = (
        Content => undef,
        @_
    );

    my ($buf, %res) = $self->_SignEncrypt(%args);
    ${ $args{'Content'} } = $$buf if $buf;
    return %res;
}

sub _SignEncrypt {
    my $self = shift;
    my %args = (
        Content => undef,

        Sign => 1,
        Signer => undef,
        Passphrase => undef,

        Encrypt => 1,
        Recipients => [],

        @_
    );

    my %res = (exit_code => 0, status => '');

    my @keys;
    if ( $args{'Encrypt'} ) {
        my @addresses = @{ $args{'Recipients'} };

        foreach my $address ( @addresses ) {
            $RT::Logger->debug( "Considering encrypting message to " . $address );

            my %key_info = $self->GetKeysInfo( Key => $address );
            unless ( defined $key_info{'info'} ) {
                $res{'exit_code'} = 1;
                my $reason = 'Key not found';
                $res{'status'} .= $self->FormatStatus({
                    Operation => 'RecipientsCheck',
                    Status => 'ERROR',
                    Message => "Recipient '$address' is unusable, the reason is '$reason'",
                    Recipient => $address,
                    Reason => $reason,
                } );
                next;
            }

            unless ( $key_info{'info'}[0]{'Expire'} ) {
                # we continue here as it's most probably a problem with the key,
                # so later during encryption we'll get verbose errors
                $RT::Logger->error(
                    "Trying to send an encrypted message to ". $address
                    .", but we couldn't get expiration date of the key."
                );
            }
            elsif ( $key_info{'info'}[0]{'Expire'}->Diff( time ) < 0 ) {
                $res{'exit_code'} = 1;
                my $reason = 'Key expired';
                $res{'status'} .= $self->FormatStatus({
                    Operation => 'RecipientsCheck', Status => 'ERROR',
                    Message => "Recipient '$address' is unusable, the reason is '$reason'",
                    Recipient => $address,
                    Reason => $reason,
                });
                next;
            }
            push @keys, $key_info{'info'}[0]{'Content'};
        }
    }
    return (undef, %res) if $res{'exit_code'};

    my $opts = RT->Config->Get('SMIME');

    my @command;
    if ( $args{'Sign'} ) {
        # XXX: implement support for -nodetach
        $args{'Passphrase'} = $self->GetPassphrase( Address => $args{'Signer'} )
            unless defined $args{'Passphrase'};

        push @command, join ' ', shell_quote(
            $self->OpenSSLPath, qw(smime -sign),
            -signer => $opts->{'Keyring'} .'/'. $args{'Signer'} .'.pem',
            -inkey  => $opts->{'Keyring'} .'/'. $args{'Signer'} .'.pem',
            (defined $args{'Passphrase'} && length $args{'Passphrase'})
                ? (qw(-passin env:SMIME_PASS))
                : (),
        );
    }
    if ( $args{'Encrypt'} ) {
        foreach my $key ( @keys ) {
            my $key_file = File::Temp->new;
            print $key_file $key;
            $key = $key_file;
        }
        push @command, join ' ', shell_quote(
            $self->OpenSSLPath, qw(smime -encrypt -des3),
            map { $_->filename } @keys
        );
    }

    my ($buf, $err) = ('', '');
    {
        local $ENV{'SMIME_PASS'} = $args{'Passphrase'};
        local $SIG{'CHLD'} = 'DEFAULT';
        safe_run_child { run3(
            join( ' | ', @command ),
            $args{'Content'},
            \$buf, \$err
        ) };
    }
    $RT::Logger->debug( "openssl stderr: " . $err ) if length $err;

    return (\$buf, %res);
}

sub VerifyDecrypt {
    my $self = shift;
    my %args = (
        Info      => undef,
        Detach    => 1,
        SetStatus => 1,
        AddStatus => 0,
        @_
    );

    my %res;

    my $item = $args{'Info'};
    if ( $item->{'Type'} eq 'signed' ) {
        my $status_on;
        if ( $item->{'Format'} eq 'RFC3156' ) {
            $status_on = $item->{'Top'};
            %res = $self->VerifyRFC3156( %$item, SetStatus => $args{'SetStatus'} );
            if ( $args{'Detach'} ) {
                $item->{'Top'}->parts( [ $item->{'Data'} ] );
                $item->{'Top'}->make_singlepart;
            }
        }
        elsif ( $item->{'Format'} eq 'RFC3851' ) {
            $status_on = $item->{'Data'};
            %res = $self->VerifyRFC3851( %$item, SetStatus => $args{'SetStatus'} );
        }
        else {
            die "Unknow signature format. Shouldn't ever happen.";
        }
        if ( $args{'SetStatus'} || $args{'AddStatus'} ) {
            my $method = $args{'AddStatus'} ? 'add' : 'set';
            # Let the header be modified so continuations are handled
            my $modify = $status_on->head->modify;
            $status_on->head->modify(1);
            $status_on->head->$method(
                'X-RT-SMIME-Status' => $res{'status'}
            );
            $status_on->head->modify($modify);
        }
    } elsif ( $item->{'Type'} eq 'encrypted' ) {
        %res = $self->DecryptRFC3851( %args, %$item );
        if ( $args{'SetStatus'} || $args{'AddStatus'} ) {
            my $method = $args{'AddStatus'} ? 'add' : 'set';
            # Let the header be modified so continuations are handled
            my $modify = $item->{'Data'}->head->modify;
            $item->{'Data'}->head->modify(1);
            $item->{'Data'}->head->$method(
                'X-RT-SMIME-Status' => $res{'status'}
            );
            $item->{'Data'}->head->modify($modify);
        }
    } else {
        die "Unknow type '". $item->{'Type'} ."' of protected item";
    }
    return %res;
}

sub VerifyRFC3156 {
    my $self = shift;
    my %args = ( Top => undef, Data => undef, Signature => undef, @_);
    return $self->VerifyRFC3851( %args, Data => $args{'Top'} );
}

sub VerifyRFC3851 {
    my $self = shift;
    my %args = (Data => undef, Queue => undef, @_ );

    my $msg = $args{'Data'}->as_string;
    $msg =~ s/\r*\n/\x0D\x0A/g;

    my %res;
    my $buf;
    my $keyfh = File::Temp->new;
    {
        local $SIG{CHLD} = 'DEFAULT';
        my $cmd = join ' ', shell_quote(
            $self->OpenSSLPath, qw(smime -verify -noverify),
            '-signer', $keyfh->filename,
        );
        safe_run_child { run3( $cmd, \$msg, \$buf, \$res{'stderr'} ) };
        $res{'exit_code'} = $?;
    }
    if ( $res{'exit_code'} ) {
        $res{'message'} = "openssl exitted with error code ". ($? >> 8)
            ." and error: $res{stderr}";
        $RT::Logger->error($res{'message'});
        return %res;
    }

    my @signers;
    if ( my $key = do { $keyfh->seek(0, 0); local $/; readline $keyfh } ) {{
        my %info = $self->GetCertificateInfo( Certificate => $key );
        last if $info{'exit_code'};

        push @signers, @{ $info{'info'} };

        my $user = RT::User->new( $RT::SystemUser );
        # if we're not going to create a user here then
        # later it will be created without key
        $user->LoadOrCreateByEmail( $signers[0]{'User'}[0]{'String'} );
        my $current_key = $user->FirstCustomFieldValue('SMIME Key');
        last if $current_key && $current_key eq $key;

        my ($status, $msg) = $user->AddCustomFieldValue(
            Field => 'SMIME Key', Value => $key,
        );
        $RT::Logger->error("Couldn't set 'SMIME Key' for user #". $user->id .": $msg")
            unless $status;
    }}

    if ( !@signers ) {
        my $pkcs7_info;
        local $SIG{CHLD} = 'DEFAULT';
        my $cmd = join( ' ', shell_quote(
            $self->OpenSSLPath, qw(smime -pk7out),
        ) );
        $cmd .= ' | '. join( ' ', shell_quote(
            $self->OpenSSLPath, qw(pkcs7 -print_certs),
        ) );
        safe_run_child { run3( $cmd, \$msg, \$pkcs7_info, \$res{'stderr'} ) };
        unless ( $? ) {
            @signers = $self->ParsePKCS7Info( $pkcs7_info );
        }
    }

    my $res_entity = _extract_msg_from_buf( \$buf, 1 );
    unless ( $res_entity ) {
        $res{'exit_code'} = 1;
        $res{'message'} = "verified message, but couldn't parse result";
        return %res;
    }

    $res_entity->make_multipart( 'mixed', Force => 1 );

    $args{'Data'}->make_multipart( 'mixed', Force => 1 );
    $args{'Data'}->parts([ $res_entity->parts ]);
    $args{'Data'}->make_singlepart;

    $res{'status'} = $self->FormatStatus({
            Operation   => 'Verify', Status => 'DONE',
            Message     => 'The signature is good',
            UserString  => $signers[0]{'User'}[0]{'String'},
        });

    return %res;
}

sub DecryptRFC3851 {
    my $self = shift;
    my %args = (Data => undef, Queue => undef, @_ );

    my $msg = $args{'Data'}->as_string;

    push @{ $args{'Recipients'} ||= [] },
        $args{'Queue'}->CorrespondAddress, RT->Config->Get('CorrespondAddress'),
        $args{'Queue'}->CommentAddress, RT->Config->Get('CommentAddress')
    ;

    my ($buf, %res) = $self->_Decrypt( %args, Content => \$args{'Data'}->as_string );
    return %res unless $buf;

    my $res_entity = _extract_msg_from_buf( $buf, 1 );
    $res_entity->make_multipart( 'mixed', Force => 1 );

    $args{'Data'}->make_multipart( 'mixed', Force => 1 );
    $args{'Data'}->parts([ $res_entity->parts ]);
    $args{'Data'}->make_singlepart;

    return %res;
}

sub DecryptContent {
    my $self = shift;
    my %args = (
        Content => undef,
        @_
    );

    my ($buf, %res) = $self->_Decrypt( %args );
    ${ $args{'Content'} } = $$buf if $buf;
    return %res;
}

sub _Decrypt {
    my $self = shift;
    my %args = (Content => undef, @_ );

    my %seen;
    my @addresses =
        grep !$seen{lc $_}++, map $_->address, map Email::Address->parse($_),
        grep length && defined, @{$args{'Recipients'}};

    my ($buf, $encrypted_to, %res);

    my $keyring = RT->Config->Get('SMIME')->{'Keyring'};
    my $found_key = 0;
    foreach my $address ( @addresses ) {
        my $key_file = File::Spec->catfile( $keyring, $address .'.pem' );
        unless ( -e $key_file && -r _ ) {
            $RT::Logger->debug("No '$key_file' or it's unreadable");
            next;
        }

        $found_key = 1;

        local $ENV{SMIME_PASS} = $self->GetPassphrase( Address => $address );
        local $SIG{CHLD} = 'DEFAULT';
        my $cmd = join( ' ', shell_quote(
            $self->OpenSSLPath,
            qw(smime -decrypt), '-recip' => $key_file,
            (defined $ENV{'SMIME_PASS'} && length $ENV{'SMIME_PASS'})
                ? (qw(-passin env:SMIME_PASS))
                : (),
        ) );
        safe_run_child { run3( $cmd, $args{'Content'}, \$buf, \$res{'stderr'} ) };
        unless ( $? ) {
            $encrypted_to = $address;
            $RT::Logger->debug("Message encrypted for $encrypted_to");
            last;
        }

        if ( index($res{'stderr'}, 'no recipient matches key') >= 0 ) {
            $RT::Logger->debug("Message was sent to $address and we have key, but it's not encrypted for this address");
            next;
        }

        $res{'exit_code'} = $?;
        $res{'message'} = "openssl exitted with error code ". ($? >> 8)
            ." and error: $res{stderr}";
        $RT::Logger->error( $res{'message'} );
        $res{'status'} = $self->FormatStatus({
            Operation => 'Decrypt', Status => 'ERROR',
            Message => 'Decryption failed',
            EncryptedTo => $address,
        });
        return (undef, %res);
    }
    unless ( $found_key ) {
        $RT::Logger->error("Couldn't find SMIME key for addresses: ". join ', ', @addresses);
        $res{'exit_code'} = 1;
        $res{'status'} = $self->FormatStatus({
            Operation => 'KeyCheck',
            Status    => 'MISSING',
            Message   => "Secret key is not available",
            KeyType   => 'secret',
        });
        return (undef, %res);
    }

    $res{'status'} = $self->FormatStatus({
        Operation => 'Decrypt', Status => 'DONE',
        Message => 'Decryption process succeeded',
        EncryptedTo => $encrypted_to,
    });

    return (\$buf, %res);
}

sub FormatStatus {
    my $self = shift;
    my @status = @_;

    my $res = '';
    foreach ( @status ) {
        while ( my ($k, $v) = each %$_ ) {
            $res .= "[SMIME:]". $k .": ". $v ."\n";
        }
        $res .= "[SMIME:]\n";
    }

    return $res;
}

sub ParseStatus {
    my $self = shift;
    my $status = shift;
    return () unless $status;

    my @status = split /\s*(?:\[SMIME:\]\s*){2}/, $status;
    foreach my $block ( grep length, @status ) {
        chomp $block;
        $block = { map { s/^\s+//; s/\s+$//; $_ } map split(/:/, $_, 2), split /\s*\[SMIME:\]/, $block };
    }
    foreach my $block ( grep $_->{'EncryptedTo'}, @status ) {
        $block->{'EncryptedTo'} = [{
            EmailAddress => $block->{'EncryptedTo'},  
        }];
    }

    return @status;
}

sub _extract_msg_from_buf {
    my $buf = shift;
    my $exact = shift;
    my $rtparser = RT::EmailParser->new();
    my $parser   = MIME::Parser->new();
    $rtparser->_SetupMIMEParser($parser);
    $parser->decode_bodies(0) if $exact;
    $parser->output_to_core(1);
    unless ( $rtparser->{'entity'} = $parser->parse_data($$buf) ) {
        $RT::Logger->crit("Couldn't parse MIME stream and extract the submessages");

        # Try again, this time without extracting nested messages
        $parser->extract_nested_messages(0);
        unless ( $rtparser->{'entity'} = $parser->parse_data($$buf) ) {
            $RT::Logger->crit("couldn't parse MIME stream");
            return (undef);
        }
    }
    return $rtparser->Entity;
}


sub CheckIfProtected {
    my $self = shift;
    my %args = ( Entity => undef, @_ );

    my $entity = $args{'Entity'};

    my $type = $entity->effective_type;
    if ( $type =~ m{^application/(?:x-)?pkcs7-mime$} || $type eq 'application/octet-stream' ) {
        # RFC3851 ch.3.9 variant 1 and 3

        my $security_type;

        my $smime_type = $entity->head->mime_attr('Content-Type.smime-type');
        if ( $smime_type ) { # it's optional according to RFC3851
            if ( $smime_type eq 'enveloped-data' ) {
                $security_type = 'encrypted';
            }
            elsif ( $smime_type eq 'signed-data' ) {
                $security_type = 'signed';
            }
            elsif ( $smime_type eq 'certs-only' ) {
                $security_type = 'certificate management';
            }
            elsif ( $smime_type eq 'compressed-data' ) {
                $security_type = 'compressed';
            }
            else {
                $security_type = $smime_type;
            }
        }

        unless ( $security_type ) {
            my $fname = $entity->head->recommended_filename || '';
            if ( $fname =~ /\.p7([czsm])$/ ) {
                my $type_char = $1;
                if ( $type_char eq 'm' ) {
                    # RFC3851, ch3.4.2
                    # it can be both encrypted and signed
                    $security_type = 'encrypted';
                }
                elsif ( $type_char eq 's' ) {
                    # RFC3851, ch3.4.3, multipart/signed, XXX we should never be here
                    # unless message is changed by some gateway
                    $security_type = 'signed';
                }
                elsif ( $type_char eq 'c' ) {
                    # RFC3851, ch3.7
                    $security_type = 'certificate management';
                }
                elsif ( $type_char eq 'z' ) {
                    # RFC3851, ch3.5
                    $security_type = 'compressed';
                }
            }
        }
        return () unless $security_type;

        my %res = (
            Type   => $security_type,
            Format => 'RFC3851',
            Data   => $entity,
        );

        if ( $security_type eq 'encrypted' ) {
            my $top = $args{'TopEntity'}->head;
            $res{'Recipients'} = [grep defined && length, map $top->get($_), 'To', 'Cc'];
        }

        return %res;
    }
    elsif ( $type eq 'multipart/signed' ) {
        # RFC3156, multipart/signed
        # RFC3851, ch.3.9 variant 2

        unless ( $entity->parts == 2 ) {
            $RT::Logger->error( "Encrypted or signed entity must has two subparts. Skipped" );
            return ();
        }

        my $protocol = $entity->head->mime_attr( 'Content-Type.protocol' );
        unless ( $protocol ) {
            $RT::Logger->error( "Entity is '$type', but has no protocol defined. Skipped" );
            return ();
        }

        unless (
            $protocol eq 'application/x-pkcs7-signature'
            || $protocol eq 'application/pkcs7-signature'
        ) {
            $RT::Logger->info( "Skipping protocol '$protocol', only 'application/pgp-signature' is supported" );
            return ();
        }
        $RT::Logger->debug("Found part signed according to RFC3156");
        return (
            Type      => 'signed',
            Format    => 'RFC3156',
            Top       => $entity,
            Data      => $entity->parts(0),
            Signature => $entity->parts(1),
        );
    }
    return ();
}

sub GetPassphrase {
    my $self = shift;
    my %args = (Address => undef, @_);
    $args{'Address'} = '' unless defined $args{'Address'};
    return RT->Config->Get('SMIME')->{'Passphrase'}->{ $args{'Address'} };
}

sub GetKeysInfo {
    my $self = shift;
    my %args = (
        Key   => undef,
        Type  => 'public',
        Force => 0,
        @_
    );

    my $email = $args{'Key'};
    unless ( $email ) {
        return (exit_code => 0); # unless $args{'Force'};
    }

    my $key = $self->GetKeyContent( %args );
    return (exit_code => 0) unless $key;

    return $self->GetCertificateInfo( Certificate => $key );
}

sub GetKeyContent {
    my $self = shift;
    my %args = ( Key => undef, @_ );

    my $key;
    if ( my $file = $self->CheckKeyring( %args ) ) {
        open my $fh, '<:raw', $file
            or die "Couldn't open file '$file': $!";
        $key = do { local $/; readline $fh };
        close $fh;
    }
    else {
        # XXX: should we use different user??
        my $user = RT::User->new( $RT::SystemUser );
        $user->LoadByEmail( $args{'Key'} );
        unless ( $user->id ) {
            return (exit_code => 0);
        }

        $key = $user->FirstCustomFieldValue('SMIME Key');
    }
    return $key;
}

sub CheckKeyring {
    my $self = shift;
    my %args = (
        Key => undef,
        @_,
    );
    my $keyring = RT->Config->Get('SMIME')->{'Keyring'};
    return undef unless $keyring;

    my $file = File::Spec->catfile( $keyring, $args{'Key'} .'.pem' );
    return undef unless -f $file;

    return $file;
}

sub GetCertificateInfo {
    my $self = shift;
    my %args = (
        Certificate => undef,
        @_,
    );

    my %res;
    my $buf;
    {
        local $SIG{CHLD} = 'DEFAULT';
        my $cmd = join ' ', shell_quote(
            $self->OpenSSLPath, 'x509',
            # everything
            '-text',
            # plus fingerprint
            '-fingerprint',
            # don't print cert itself
            '-noout',
            # don't dump signature and pubkey info, header is useless too
            '-certopt', 'no_pubkey,no_sigdump,no_extensions',
            # subject and issuer are multiline, long prop names, utf8
            '-nameopt', 'sep_multiline,lname,utf8',
        );
        safe_run_child { run3( $cmd, \$args{'Certificate'}, \$buf, \$res{'stderr'} ) };
        $res{'exit_code'} = $?;
    }
    if ( $res{'exit_code'} ) {
        $res{'message'} = "openssl exitted with error code ". ($? >> 8)
            ." and error: $res{stderr}";
        return %res;
    }

    my %info = $self->CanonicalizeInfo( $self->ParseCertificateInfo( $buf ) );
    $info{'Content'} = $args{'Certificate'};
    $res{'info'} = [\%info];
    return %res;
}

my %SHORT_NAMES = (
    C => 'Country',
    ST => 'StateOrProvince',
    O  => 'Organization',
    OU => 'OrganizationUnit',
    CN => 'Name',
);
my %LONG_NAMES = (
    countryName => 'Country',
    stateOrProvinceName => 'StateOrProvince',
    organizationName => 'Organization',
    organizationalUnitName => 'OrganizationUnit',
    commonName => 'Name',
    emailAddress => 'EmailAddress',
);

sub CanonicalizeInfo {
    my $self = shift;
    my %info = @_;

    my %res = (
        # XXX: trust is not implmented for SMIME
        TrustLevel => 1,
    );
    if ( my $subject = delete $info{'Certificate'}{'Data'}{'Subject'} ) {
        $res{'User'} = [
            { $self->CanonicalizeUserInfo( %$subject ) },
        ];
    }
    if ( my $issuer = delete $info{'Certificate'}{'Data'}{'Issuer'} ) {
        $res{'Issuer'} = [
            { $self->CanonicalizeUserInfo( %$issuer ) },
        ];
    }
    if ( my $validity = delete $info{'Certificate'}{'Data'}{'Validity'} ) {
        $res{'Created'} = $self->ParseDate( $validity->{'Not Before'} );
        $res{'Expire'} = $self->ParseDate( $validity->{'Not After'} );
    }
    {
        $res{'Fingerprint'} = delete $info{'SHA1 Fingerprint'};
    }
    %res = (%{$info{'Certificate'}{'Data'}}, %res);
    return %res;
}

sub ParseCertificateInfo {
    my $self = shift;
    my $info = shift;

    my @lines = split /\n/, $info;

    my %res;
    my %prefix = ();
    my $first_line = 1;
    my $prev_prefix = '';
    my $prev_key = '';

    foreach my $line ( @lines ) {
        # some examples:
        # Validity # no trailing ':'
        # Not After : XXXXXX # space before ':'
        # countryName=RU # '=' as separator
        # Serial Number:
        #     he:xv:al:ue
        my ($prefix, $key, $value) = ($line =~ /^(\s*)(.*?)\s*(?:(?:=\s*|:\s+)(\S.*?)|:|)\s*$/);
        if ( $first_line ) {
            $prefix{$prefix} = \%res;
            $first_line = 0;
        }

        my $put_into = ($prefix{$prefix} ||= $prefix{$prev_prefix}{$prev_key});
        unless ( $put_into ) {
            die "Couldn't parse key info: $info";
        }

        if ( defined $value && length $value ) {
            $put_into->{$key} = $value;
        }
        else {
            $put_into->{$key} = {};
            delete $prefix{$_} foreach
                grep length($_) > length($prefix),
                keys %prefix;

            ($prev_prefix, $prev_key) = ($prefix, $key);
        }
    }

    my ($filter_out, $wfilter_out);
    $filter_out = $wfilter_out = sub {
        my $h = shift;
        foreach my $e ( keys %$h ) {
            next unless ref $h->{$e};
            if ( 1 == keys %{$h->{$e}} ) {
                my $sube = (keys %{$h->{$e}})[0];
                if ( ref $h->{$e}{$sube} && !keys %{ $h->{$e}{$sube} } ) {
                    $h->{$e} = $sube;
                    next;
                }
            }

            $filter_out->( $h->{$e} );
        }
    };
    Scalar::Util::weaken($wfilter_out);

    $filter_out->(\%res);

    return %res;
}

sub ParsePKCS7Info {
    my $self = shift;
    my $string = shift;

    return () unless defined $string && length $string && $string =~ /\S/;

    my @res = ({});
    foreach my $str ( split /\r*\n/, $string ) {
        if ( $str =~ /^\s*$/ ) {
            push @res, {} if keys %{ $res[-1] };
        } elsif ( my ($who, $values) = ($str =~ /^(subject|issuer)=(.*)$/i) ) {
            my %info;
            while ( $values =~ s{^/([a-z]+)=(.*?)(?=$|/[a-z]+=)}{}i ) {
                $info{ $1 } = $2;
            }
            die "Couldn't parse PKCS7 info: $string" if $values;

            $res[-1]{ ucfirst lc $who } = { $self->CanonicalizeUserInfo( %info ) };
        }
        else {
            $res[-1]{'Content'} ||= '';
            $res[-1]{'Content'} .= $str ."\n";
        }
    }

    # oddly, but a certificate can be duplicated
    my %seen;
    @res = grep !$seen{ $_->{'Content'} }++, grep keys %$_, @res;
    $_->{'User'} = [delete $_->{'Subject'}] foreach @res;

    return @res;
}

sub CanonicalizeUserInfo {
    my $self = shift;
    my %info = @_;

    my %res;
    while ( my ($k, $v) = each %info ) {
        $res{ $SHORT_NAMES{$k} || $LONG_NAMES{$k} || $k } = $v;
    }
    if ( $res{'EmailAddress'} ) {
        my $email = Email::Address->new( @res{'Name', 'EmailAddress'} );
        $res{'String'} = $email->format;
    }
    return %res;
}

1;
