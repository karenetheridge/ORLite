#!/usr/bin/perl

# Tests that overlay modules are automatically loaded

BEGIN {
	$|  = 1;
	$^W = 1;
}

use Test::More tests => 7;
use File::Spec::Functions ':ALL';
use lib 't/lib';
use LocalTest;





#####################################################################
# Set up for testing

# Connect
my $file = test_db();
my $dbh  = create_ok(
	file    => catfile(qw{ t 02_basics.sql }),
	connect => [ "dbi:SQLite:$file" ],
);

# Create the test package
eval <<"END_PERL"; die $@ if $@;
package OverlayTest;

use strict;
use ORLite {
	file => '$file',
};

1;
END_PERL





#####################################################################
# Tests for the base package update methods

isa_ok(
	OverlayTest::TableOne->create(
		col1 => 1,
		col2 => 'foo',
	),
	'OverlayTest::TableOne',
);

isa_ok(
	OverlayTest::TableOne->create(
		col1 => 2,
		col2 => 'bar',
	),
	'OverlayTest::TableOne',
);
is( OverlayTest::TableOne->count, 2, 'Found 2 rows' );

is(
	OverlayTest::TableOne->count,
	2,
	'Count found 2 rows',
);

SCOPE: {
	my $object = OverlayTest::TableOne->load(1);
	isa_ok( $object, 'OverlayTest::TableOne' );
	is( $object->dummy, 2, '->dummy ok (overlay was loaded)' );
}
