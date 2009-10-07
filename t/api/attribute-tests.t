use strict;
use warnings;
use RT::Test; use Test::More tests => 34;



my $runid = rand(200);

my $attribute = "squelch-$runid";

ok(require RT::Model::AttributeCollection);

my $user = RT::Model::User->new(current_user => RT->system_user);
ok (UNIVERSAL::isa($user, 'RT::Model::User'));
my ($id,$msg)  = $user->create(name => 'attrtest-'.$runid);
ok ($id, $msg);
ok($user->id, "Created a test user");

ok(1, $user->attributes->build_select_query);
my $attr = $user->attributes;
# XXX: order by id as some tests depend on it
$attr->order_by({ column => 'id' });

ok(1, $attr->build_select_query);


ok (UNIVERSAL::isa($attr,'RT::Model::AttributeCollection'), 'got the attributes object');

($id, $msg) =  $user->add_attribute(name => 'TestAttr', content => 'The attribute has content'); 
ok ($id, $msg);
is ($attr->count,1, " One attr after adding a first one");

my $first_attr = $user->first_attribute('TestAttr');
ok($first_attr, "got some sort of attribute");
isa_ok($first_attr, 'RT::Model::Attribute');
is($first_attr->content, 'The attribute has content', "got the right content back");

($id, $msg) = $attr->delete_entry(name => $runid);
ok(!$id, "Deleted non-existant entry  - $msg");
is ($attr->count,1, "1 attr after deleting an empty attr");

my @names = $attr->names;
is ("@names", "TestAttr");


($id, $msg) = $user->add_attribute(name => $runid, content => "First");
ok($id, $msg);

my $runid_attr = $user->first_attribute($runid);
ok($runid_attr, "got some sort of attribute");
isa_ok($runid_attr, 'RT::Model::Attribute');
is($runid_attr->content, 'First', "got the right content back");

is ($attr->count,2, " Two attrs after adding an attribute named $runid");
($id, $msg) = $user->add_attribute(name => $runid, content => "Second");
ok($id, $msg);

$runid_attr = $user->first_attribute($runid);
ok($runid_attr, "got some sort of attribute");
isa_ok($runid_attr, 'RT::Model::Attribute');
is($runid_attr->content, 'First', "got the first content back still");

is ($attr->count,3, " Three attrs after adding a secondvalue to $runid");
($id, $msg) = $attr->delete_entry(name => $runid, content => "First");
ok($id, $msg);
is ($attr->count,2);

#$attr->_do_search();
($id, $msg) = $attr->delete_entry(name => $runid, content => "Second");
ok($id, $msg);
is ($attr->count,1);

#$attr->_do_search();
ok(1, $attr->build_select_query);
($id, $msg) = $attr->delete_entry(name => "moose");
ok(!$id, "Deleted non-existant entry - $msg");
is ($attr->count,1);

ok(1, $attr->build_select_query);
@names = $attr->names;
is("@names", "TestAttr");



1;