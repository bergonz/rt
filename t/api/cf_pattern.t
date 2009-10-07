#!/usr/bin/perl
use warnings;
use strict;
use RT::Test; use Test::More tests => 17;

use RT;



sub fails { ok(!$_[0], "This should fail: $_[1]") }
sub works { ok($_[0], $_[1] || 'This works') }

sub new {
    my $class = shift;
    return $class->new(current_user => RT->system_user);
}

my $q = new('RT::Model::Queue');
works($q->create(name => "CF-Pattern-".$$));

my $cf = new('RT::Model::CustomField');
my @cf_args = (name => $q->name, type => 'Freeform', queue => $q->id, max_values => 1);

fails($cf->create(@cf_args, pattern => ')))bad!regex((('));
works($cf->create(@cf_args, pattern => 'good regex'));

my $t = new('RT::Model::Ticket');
my ($id,undef,$msg) = $t->create(queue => $q->id, subject => 'CF Test');
works($id,$msg);

# OK, I'm thoroughly brain washed by HOP at this point now...
sub cnt { $t->custom_field_values($cf->id)->count };
sub add { $t->add_custom_field_value(field => $cf->id, value => $_[0]) };
sub del { $t->delete_custom_field_value(field => $cf->id, value => $_[0]) };

is(cnt(), 0, "No values yet");
fails(add('not going to match'));
is(cnt(), 0, "No values yet");
works(add('here is a good regex'));
is(cnt(), 1, "Value filled");
fails(del('here is a good regex'));
is(cnt(), 1, "Single CF - Value _not_ deleted");

$cf->set_max_values(0);   # unlimited max_values

works(del('here is a good regex'));
is(cnt(), 0, "Multiple CF - Value deleted");

fails($cf->set_pattern('(?{ "insert evil code here" })'));
works($cf->set_pattern('(?!)')); # reject everything
fails(add(''));
fails(add('...'));

# Avoid global destruction issues
undef $t;

1;