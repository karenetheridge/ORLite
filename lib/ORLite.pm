package ORLite;

# See POD at end of file for documentation

use 5.006;
use strict;
use Carp              ();
use File::Spec   0.80 ();
use File::Temp   0.20 ();
use File::Path   2.04 ();
use File::Basename  0 ();
use Params::Util 0.33 ();
use DBI         1.607 ();
use DBD::SQLite  1.27 ();

use vars qw{$VERSION};
BEGIN {
	$VERSION = '1.36';
}

# Support for the 'prune' option
my @PRUNE = ();
END {
	foreach ( reverse @PRUNE ) {
		next unless -e $_;
		require File::Remove;
		File::Remove::remove( \1, $_ );
	}
}





#####################################################################
# Code Generation

sub import {
	my $class = ref($_[0]) || $_[0];

	# Check for debug mode
	my $DEBUG = 0;
	if ( defined Params::Util::_STRING($_[-1]) and $_[-1] eq '-DEBUG' ) {
		$DEBUG = 1;
		pop @_;
	}

	# Check params and apply defaults
	my %params;
	if ( defined Params::Util::_STRING($_[1]) ) {
		# Support the short form "use ORLite 'db.sqlite'"
		%params = (
			file     => $_[1],
			readonly => undef, # Automatic
			package  => undef, # Automatic
			tables   => 1,
		);
	} elsif ( Params::Util::_HASHLIKE($_[1]) ) {
		%params = %{ $_[1] };
	} else {
		Carp::croak("Missing, empty or invalid params HASH");
	}
	unless ( defined $params{create} ) {
		$params{create} = 0;
	}
	unless (
		defined Params::Util::_STRING($params{file})
		and (
			$params{create}
			or
			-f $params{file}
		)
	) {
		Carp::croak("Missing or invalid file param");
	}
	unless ( defined $params{readonly} ) {
		$params{readonly} = $params{create} ? 0 : ! -w $params{file};
	}
	unless ( defined $params{cleanup} ) {
		$params{cleanup} = '';
	}
	unless ( defined $params{xsaccessor} ) {
		$params{xsaccessor} = 0;
	}
	unless ( defined $params{tables} ) {
		$params{tables} = 1;
	}
	unless ( defined $params{package} ) {
		$params{package} = scalar caller;
	}
	unless ( Params::Util::_CLASS($params{package}) ) {
		Carp::croak("Missing or invalid package class");
	}

	# Connect to the database
	my $file     = File::Spec->rel2abs($params{file});
	my $created  = ! -f $params{file};
	if ( $created ) {
		# Create the parent directory
		my $dir = File::Basename::dirname($file);
		unless ( -d $dir ) {
			my @dirs = File::Path::mkpath( $dir, { verbose => 0 } );
			$class->prune(@dirs) if $params{prune};
		}
		$class->prune($file) if $params{prune};
	}
	my $pkg         = $params{package};
	my $readonly    = $params{readonly};
	my $cleanup     = $params{cleanup};
	my $xsaccessor  = $params{xsaccessor};
	my $dsn         = "dbi:SQLite:$file";
	my $dbh         = DBI->connect( $dsn, undef, undef, {
		PrintError => 0,
		RaiseError => 1,
	} );

	# Schema creation support
	if ( $created and Params::Util::_CODELIKE($params{create}) ) {
		$params{create}->( $dbh );
	}

	# Check the schema version before generating
	my $version  = $dbh->selectrow_arrayref('pragma user_version')->[0];
	if ( exists $params{user_version} and $version != $params{user_version} ) {
		Carp::croak("Schema user_version mismatch (got $version, wanted $params{user_version})");
	}

	# Generate the support package code
	my $code = <<"END_PERL";
package $pkg;

use strict;
use Carp              ();
use DBI         1.607 ();
use DBD::SQLite  1.27 ();

my \$DBH = undef;

sub orlite { '$VERSION' }

sub sqlite { '$file' }

sub dsn { '$dsn' }

sub dbh {
	\$DBH or \$_[0]->connect;
}

sub connect {
	DBI->connect( \$_[0]->dsn, undef, undef, {
		PrintError => 0,
		RaiseError => 1,
	} );
}

sub prepare {
	shift->dbh->prepare(\@_);
}

sub do {
	shift->dbh->do(\@_);
}

sub selectall_arrayref {
	shift->dbh->selectall_arrayref(\@_);
}

sub selectall_hashref {
	shift->dbh->selectall_hashref(\@_);
}

sub selectcol_arrayref {
	shift->dbh->selectcol_arrayref(\@_);
}

sub selectrow_array {
	shift->dbh->selectrow_array(\@_);
}

sub selectrow_arrayref {
	shift->dbh->selectrow_arrayref(\@_);
}

sub selectrow_hashref {
	shift->dbh->selectrow_hashref(\@_);
}

sub pragma {
	\$_[0]->do("pragma \$_[1] = \$_[2]") if \@_ > 2;
	\$_[0]->selectrow_arrayref("pragma \$_[1]")->[0];
}

sub iterate {
	my \$class = shift;
	my \$call  = pop;
	my \$sth   = \$class->prepare( shift );
	\$sth->execute( \@_ );
	while ( \$_ = \$sth->fetchrow_arrayref ) {
		\$call->() or last;
	}
	\$sth->finish;
}

sub begin {
	\$DBH or
	\$DBH = \$_[0]->connect;
	\$DBH->begin_work;
}

sub rollback {
	\$DBH or return 1;
	\$DBH->rollback;
	\$DBH->disconnect;
	undef \$DBH;
	return 1;
}

sub rollback_begin {
	if ( \$DBH ) {
		\$DBH->rollback;
		\$DBH->begin_work;
	} else {
		\$_[0]->begin;
	}
	return 1;
}

END_PERL

	# If you are a read-write database, we even allow you
	# to commit your transactions.
	$code .= <<"END_PERL" unless $readonly;
sub commit {
	\$DBH or return 1;
	\$DBH->commit;
	\$DBH->disconnect;
	undef \$DBH;
	return 1;
}

sub commit_begin {
	if ( \$DBH ) {
		\$DBH->commit;
		\$DBH->begin_work;
	} else {
		\$_[0]->begin;
	}
	return 1;
}

END_PERL

	# Cleanup and shutdown operations
	if ( $cleanup ) {
		$code .= <<"END_PERL";
END {
	if ( \$DBH ) {
		\$DBH->rollback;
		\$DBH->do('$cleanup');
		\$DBH->disconnect;
		undef \$DBH;
	} else {
		$pkg->do('$cleanup');
	}
}

END_PERL
	} else {
		$code .= <<"END_PERL";
END {
	$pkg->rollback if \$DBH;
}

END_PERL
	}

	# Optionally generate the table classes
	if ( $params{tables} ) {
		# Capture the raw schema information
		my $tables = $dbh->selectall_arrayref(
			'select * from sqlite_master where name not like ? and type = ?',
			{ Slice => {} }, 'sqlite_%', 'table',
		);
		foreach my $table ( @$tables ) {
			$table->{columns} = $dbh->selectall_arrayref(
				"pragma table_info('$table->{name}')",
			 	{ Slice => {} },
			);
		}

		# Generate the main additional table level metadata
		my %tindex = map { $_->{name} => $_ } @$tables;
		foreach my $table ( @$tables ) {
			my @columns      = @{ $table->{columns} };
			my @names        = map { $_->{name} } @columns;
			$table->{cindex} = map { $_->{name} => $_ } @columns;

			# Discover the primary key
			@{$table->{pk}}  = map($_->{name}, grep { $_->{pk} } @columns);
			$table->{pks}    = scalar(@{$table->{pk}});

			# What will be the class for this table
			$table->{class}  = ucfirst lc $table->{name};
			$table->{class}  =~ s/_([a-z])/uc($1)/ge;
			$table->{class}  = "${pkg}::$table->{class}";

			# Generate various SQL fragments
			my $sql = $table->{sql} = { create => $table->{sql} };
			$sql->{cols}     = join ', ', map { '"' . $_ . '"' } @names;
			$sql->{vals}     = join ', ', ('?') x scalar @columns;
			$sql->{select}   = "select $table->{sql}->{cols} from $table->{name}";
			$sql->{count}    = "select count(*) from $table->{name}";
			$sql->{insert}   = join ' ',
				"insert into $table->{name}" .
				"( $table->{sql}->{cols} )"  .
				" values ( $table->{sql}->{vals} )";
			$sql->{where_pk}    = join(' and ', map("$_ = ?", @{$table->{pk}}))
		}

		# Generate the foreign key metadata
		foreach my $table ( @$tables ) {
			# Locate the foreign keys
			my %fk     = ();
			my @fk_sql = $table->{sql}->{create} =~ /[(,]\s*(.+?REFERENCES.+?)\s*[,)]/g;

			# Extract the details
			foreach ( @fk_sql ) {
				unless ( /^(\w+).+?REFERENCES\s+(\w+)\s*\(\s*(\w+)/ ) {
					die "Invalid foreign key $_";
				}
				$fk{"$1"} = [ "$2", $tindex{"$2"}, "$3" ];
			}
			foreach ( @{ $table->{columns} } ) {
				$_->{fk} = $fk{$_->{name}};
			}
		}

		# Generate the per-table code
		foreach my $table ( @$tables ) {
			# Generate the accessors
			my $sql     = $table->{sql};
			my @columns = @{ $table->{columns} };
			my @names   = map { $_->{name} } @columns;

			# Generate the elements in all packages
			$code .= <<"END_PERL";
package $table->{class};

sub base { '$pkg' }

sub table { '$table->{name}' }

sub select {
	my \$class = shift;
	my \$sql   = '$sql->{select} ';
	   \$sql  .= shift if \@_;
	my \$rows  = $pkg->selectall_arrayref( \$sql, { Slice => {} }, \@_ );
	bless( \$_, '$table->{class}' ) foreach \@\$rows;
	wantarray ? \@\$rows : \$rows;
}

sub count {
	my \$class = shift;
	my \$sql   = '$sql->{count} ';
	   \$sql  .= shift if \@_;
	$pkg->selectrow_array( \$sql, {}, \@_ );
}

sub iterate {
	my \$class = shift;
	my \$call  = pop;
	my \$sql   = '$sql->{select} ';
	   \$sql  .= shift if \@_;
	my \$sth   = $pkg->prepare( \$sql );
	\$sth->execute( \@_ );
	while ( \$_ = \$sth->fetchrow_hashref ) {
		bless( \$_, '$table->{class}' );
		\$call->() or last;
	}
	\$sth->finish;
}

END_PERL

			# Add the primary key based single object loader
			if ( $table->{pks} ) {
				$code .= <<"END_PERL";
sub load {
	my \$class = shift;
	my \$row   = $pkg->selectrow_hashref(
		'$sql->{select} where $sql->{where_pk}',
		undef, \@_,
	);
	unless ( \$row ) {
		Carp::croak("$table->{class} row does not exist");
	}
	bless( \$row, '$table->{class}' );
}

END_PERL
			}

			# Generate the elements for tables with primary keys
			if ( defined $table->{pk} and ! $readonly ) {
				my $nattr = join "\n", map { "\t\t$_ => \$attr{$_}," } @names;
				my $iattr = join "\n", map { "\t\t\$self->{$_},"       } @names;
				my $fill_pk = scalar @{$table->{pk}} == 1 
					? "\t\$self->{$table->{pk}->[0]} = \$dbh->func('last_insert_rowid') unless \$self->{$table->{pk}->[0]};"
					: q{};
				my $where_pk      = join(' and ', map("$_ = ?", @{$table->{pk}}));
				my $where_pk_attr = join("\n", map("\t\t\$self->{$_},", @{$table->{pk}}));
				$code .= <<"END_PERL";
sub new {
	my \$class = shift;
	my \%attr  = \@_;
	bless {
$nattr
	}, \$class;
}

sub create {
	shift->new(\@_)->insert;
}

sub insert {
	my \$self = shift;
	my \$dbh  = $pkg->dbh;
	\$dbh->do( '$sql->{insert}', {},
$iattr
	);
$fill_pk	
	return \$self;
}

sub delete {
	my \$self = shift;
	return $pkg->do(
		'delete from $table->{name} where $where_pk',
		{}, 
$where_pk_attr		
	) if ref \$self;
	Carp::croak("Must use truncate to delete all rows") unless \@_;
	return $pkg->do(
		'delete from $table->{name} ' . shift,
		{}, \@_,
	);
}

sub truncate {
	$pkg->do( 'delete from $table->{name}', {} );
}

END_PERL

			}

		# Generate the boring accessors
		if ( $xsaccessor ) {
			my $attrs = join( "\n",
				map { "\t\t$_->{name} => '$_->{name}'," } grep { ! $_->{fk} } @columns
			);
			$code .= <<"END_PERL";
use Class::XSAccessor 1.05 {
	getters => {
$attrs
	},
};

END_PERL
		} else {
			$code .= join "\n\n", map { <<"END_PERL" } grep { ! $_->{fk} } @columns;
sub $_->{name} {
	\$_[0]->{$_->{name}};
}
END_PERL
		}

		# Generate the foreign key accessors
		$code .= join "\n\n", map { <<"END_PERL" } grep { $_->{fk} } @columns;
sub $_->{name} {
	($_->{fk}->[1]->{class}\->select('where $_->{fk}->[1]->{pk}->[0] = ?', \$_[0]->{$_->{name}}))[0];
}
END_PERL
		}
	}
	$dbh->disconnect;

	# Add any custom code to the end
	if ( defined $params{append} ) {
		$code .= "\npackage $pkg;\n" if $params{tables};
		$code .= "\n$params{append}";
	}
	$code .= "\n\n1;\n";

	# Compile the code
	local $@;
	if ( $^P and $^V >= 5.008009 ) {
		local $^P = $^P | 0x800;
		eval $code;
		die $@ if $@;
	} elsif ( $DEBUG ) {
		dval($code);
	} else {
		eval $code;
		die $@ if $@;
	}

	return 1;
}

sub dval {
	# Write the code to the temp file
	my ($fh, $filename) = File::Temp::tempfile();
	$fh->print($_[0]);
	close $fh;
	require $filename;
	unlink $filename;

	# Print the debugging output
	my @trace = map {
		s/\s*[{;]$//;
		s/^s/  s/;
		s/^p/\np/;
		"$_\n"
	} grep {
		/^(?:package|sub)\b/
	} split /\n/, $_[0];
	# print STDERR @trace, "\nCode saved as $filename\n\n";

	return 1;
}

sub prune {
	my $class = shift;
	push @PRUNE, map { File::Spec->rel2abs($_) } @_;
}

1;

__END__

=pod

=head1 NAME

ORLite - Extremely light weight SQLite-specific ORM

=head1 SYNOPSIS

  package Foo;
  
  # Simplest possible usage
  
  use strict;
  use ORLite 'data/sqlite.db';
  
  my @awesome = Foo::Person->select(
     'where first_name = ?',
     'Adam',
  );
  
  package Bar;
  
  # All available options enabled or specified.
  # Some options shown are mutually exclusive,
  # this code would not actually run.
  
  use ORLite {
      package      => 'My::ORM',
      file         => 'data/sqlite.db',
      user_version => 12,
      readonly     => 1,
      create       => sub {
          my $dbh = shift;
          $dbh->do('CREATE TABLE foo ( bar TEXT NOT NULL )');
      },
      tables       => [ 'table1', 'table2' ],
      cleanup      => 'VACUUM',
      prune        => 1,
  );

=head1 DESCRIPTION

L<SQLite> is a light single file SQL database that provides an
excellent platform for embedded storage of structured data.

However, while it is superficially similar to a regular server-side SQL
database, SQLite has some significant attributes that make using it like
a traditional database difficult.

For example, SQLite is extremely fast to connect to compared to server
databases (1000 connections per second is not unknown) and is
particularly bad at concurrency, as it can only lock transactions at
a database-wide level.

This role as a superfast internal data store can clash with the roles and
designs of traditional object-relational modules like L<Class::DBI> or
L<DBIx::Class>.

What this situation would seem to need is an object-relation system that is
designed specifically for SQLite and is aligned with its idiosyncracies.

ORLite is an object-relation system specifically tailored for SQLite that
follows many of the same principles as the ::Tiny series of modules and
has a design and feature set that aligns directly to the capabilities of
SQLite.

Further documentation will be available at a later time, but the synopsis
gives a pretty good idea of how it works.

=head2 How ORLite Works

In short, ORLite discovers the schema of a SQLite database, and then uses
code generation to build a set of packages for talking to that database.

In the simplest form, your target root package "uses" ORLite, which will do
the schema discovery and code generation at compile-time.

When called, ORLite generates two types of package.

Firstly, it builds database connectivity, transaction support, and other
purely database level functionality into your root namespace.

Then it will create one sub-package underneath the root package for each
table contained in the database.

=head1 OPTIONS

ORLite takes a set of options for the class construction at compile time
as a HASH parameter to the "use" line.

As a convenience, you can pass just the name of an existing SQLite file
to load, and ORLite will apply defaults to all other options.

  # The following are equivalent
  
  use ORLite $filename;
  
  use ORLite {
      file => $filename,
  };

The behaviour of each of the options is as follows:

=head2 package

The optional C<package> parameter is used to provide the Perl root namespace to generate
the code for. This class does not need to exist as a module on disk,
nor does it need to have anything loaded or in the namespace.

By default, the package used is the package that is calling ORLite's import
method (typically via the C<use ORLite { ... }> line).

=head2 file

The compulsory C<file> parameter (the only compulsory parameter) provides
the path to the SQLite file to use for the ORM class tree.

If the file already exists, it must be a valid SQLite file match that
supported by the version of L<DBD::SQLite> that is installed on your
system.

L<ORLite> will throw an exception if the file does not exist, B<unless>
you also provide the C<create> option to signal that L<ORLite> should
create a new SQLite file on demand.

If the C<create> option is provided, the path provided must be creatable.
When creating the database, L<ORLite> will also create any missing
directories as needed.

=head2 user_version

When working with ORLite, the biggest risk to the stability of your code
is often the reliability of the SQLite schema structure over time.

When the database schema changes the code generated by ORLite will also
change. This can easily result in an unexpected change in the API of your
class tree, breaking the code that sits on top of those generated APIs.

To resolve this, L<ORLite> supports a feature called schema version-locking.

Via the C<user_version> SQLite pragma, you can set a revision for your
database schema, increasing the number each time to make a non-trivial
chance to your schema.

  SQLite> PRAGMA user_version = 7

When creating your L<ORLite> package, you should specificy this schema
version number via the C<user_version> option.

  use ORLite {
      file         => $filename,
      user_version => 7,
  };

When connecting to the SQLite database, the C<user_version> you provide
will be checked against the version in the schema. If the versions do
not match, then the schema has unexpectedly changed, and the code that
is generated by L<ORLite> would be different to the expected API.

Rather than risk potentially destructive errors caused by the changing
code, L<ORLite> will simply refuse to run and throw an exception.

Thus, using the C<user_version> feature allows you to write code against
a SQLite database with high-certainty that it will continue to work. Or
at the very least, that should the SQLite schema change in the future your
code fill fail quickly and safely instead of running away and causing
unknown behaviour.

By default, the C<user_version> option is false and the value of
the SQLite C<PRAGMA user_version> will B<not> be checked.

=head2 readonly

To conserve memory and reduce complexity, L<ORLite> will generate the API
differently based on the writability of the SQLite database.

Features like transaction support and methods that result in C<INSERT>,
C<UPDATE> and C<DELETE> queries will only be added if they can actually
be run, resulting in an immediate "no such method" exception at the Perl
level instead of letting the application do more work only to hit an
inevitable SQLite error.

By default, the C<reaodnly> option is based on the filesystem permissions
of the SQLite database (which matches SQLite's own writability behaviour).

However the C<readonly> option can be explicitly provided if you wish.
Generally you would do this if you are working with a read-write database,
but you only plan to read from it.

Forcing C<readonly> to true will halve the size of the code that is
generated to produce your ORM, reducing the size of any auto-generated
API documentation using L<ORLite::Pod> by a similar amount.

It also ensures that this process will only take shared read locks on the
database (preventing the chance of creating a dead-lock on the SQLite
database).

=head2 create

The C<create> option is used to expand L<ORLite> beyond just consuming
other people's databases to produce and operating on databases user the
direct control of your code.

The C<create> option supports two alternative forms.

If C<create> is set to a simple true value, an empty SQLite file will be
created if the location provided in the C<file> option does not exist.

If C<create> is set to a C<CODE> reference, this function will be executed
on the new database B<before> L<ORLite> attempts to scan the schema.

The C<CODE> reference will be passed a plain L<DBI> connection handle,
which you should operate on normally. Note that because C<create> is fired
before the code generation phase, none of the functionality produced by
the generated classes is available during the execution of the C<create>
code.

The use of C<create> option is incompatible with the C<readonly> option.

=head2 tables

The C<tables> option should be a reference to an array containing a list
of table names. For large or complex SQLite databases where you only need
to make use of a fraction of the schema limiting the set of tables
will reduce both the startup time needed to scan the structure of the
SQLite schema, and reduce the memory cost of the class tree.

If the C<tables> option is not provided, L<ORLite> will attempt to produce
a class for every table in the main schema that is not prefixed with 
with C<sqlite_>.

=head2 cleanup

When working with embedded SQLite database containing rapidly changing
state data, it is important for database performance and general health
to make sure you VACUUM or ANALYZE the database regularly.

The C<cleanup> option should be a single literal SQL statement.

If provided, this statement will be automatically run on the database
during C<END>-time, after the last transaction has been completed.

This will typically either by a full C<'VACUUM ANALYZE'> or the more
simple C<'VACUUM'>.

=head2 prune

In some situation, such as during test scripts, an application will only
need the created SQLite database temporarily. In these situations, the
C<prune> option can be provided to instruct L<ORLite> to delete the
SQLite database when the program ends.

If any directories were made in order to create the SQLite file, these
directories will be cleaned up and removed as well.

If C<prune> is enabled, you should generally not use C<cleanup> as any
cleanup operation will be made pointless when C<prune> deletes the file.

By default, the C<prune> option is set to false.

=head1 ROOT PACKAGE METHODS

All ORLite root packages receive an identical set of methods for
controlling connections to the database, transactions, and the issueing
of queries of various types to the database.

The example root package Foo::Bar is used in any examples.

All methods are static, ORLite does not allow the creation of a Foo::Bar
object (although you may wish to add this capability yourself).

=head2 dsn

  my $string = Foo::Bar->dsn;

The C<dsn> accessor returns the dbi connection string used to connect
to the SQLite database as a string.

=head2 dbh

  my $handle = Foo::Bar->dbh;

To reliably prevent potential SQLite deadlocks resulting from multiple
connections in a single process, each ORLite package will only ever
maintain a single connection to the database.

During a transaction, this will be the same (cached) database handle.

Although in most situations you should not need a direct DBI connection
handle, the C<dbh> method provides a method for getting a direct
connection in a way that is compatible with ORLite's connection
management.

Please note that these connections should be short-lived, you should
never hold onto a connection beyond the immediate scope.

The transaction system in ORLite is specifically designed so that code
using the database should never have to know whether or not it is in a
transation.

Because of this, you should B<never> call the -E<gt>disconnect method
on the database handles yourself, as the handle may be that of a
currently running transaction.

Further, you should do your own transaction management on a handle
provided by the <dbh> method.

In cases where there are extreme needs, and you B<absolutely> have to
violate these connection handling rules, you should create your own
completely manual DBI-E<gt>connect call to the database, using the connect
string provided by the C<dsn> method.

The C<dbh> method returns a L<DBI::db> object, or throws an exception on
error.

=head2 begin

  Foo::Bar->begin;

The C<begin> method indicates the start of a transaction.

In the same way that ORLite allows only a single connection, likewise
it allows only a single application-wide transaction.

No indication is given as to whether you are currently in a transaction
or not, all code should be written neutrally so that it works either way
or doesn't need to care.

Returns true or throws an exception on error.

While transaction support is always built for every L<ORLite>-generated
class tree, if the database is opened C<readonly> the C<commit> method
will not exist at all in the API, and your only way of ending the
transaction (and the resulting persistant connection) will be C<rollback>.

=head2 commit

  Foo::Bar->commit;

The C<commit> method commits the current transaction. If called outside
of a current transaction, it is accepted and treated as a null operation.

Once the commit has been completed, the database connection falls back
into auto-commit state. If you wish to immediately start another
transaction, you will need to issue a separate -E<gt>begin call.

Returns true or throws an exception on error.

=head2 commit_begin

  Foo::Bar->begin;
  
  # Code for the first transaction...
  
  Foo::Bar->commit_begin;
  
  # Code for the last transaction...
  
  Foo::Bar->commit;

By default, L<ORLite>-generated code uses opportunistic connections.

Every <select> you call results in a fresh L<DBI> C<connect>, and a
C<disconnect> occurs after query processing and before the data is
returned. Connections are B<only> held open indefinitely during a
transaction, with an immediate C<disconnect> after your C<commit>.

This makes ORLite very easy to use in an ad-hoc manner, but can have
performance implications.

While SQLite itself can handle 1000 connections per second, the repeated
destruction and repopulation of SQLite's data page caches between your
statements (or between transactions) can slow things down dramatically.

The C<commit_begin> method is used to C<commit> the current transaction
and immediately start a new transaction, without disconnecting from the
database.

Its exception behaviour and return value is identical to that of a plain
C<commit> call.

=head2 rollback

The C<rollback> method rolls back the current transaction. If called outside
of a current transaction, it is accepted and treated as a null operation.

Once the rollback has been completed, the database connection falls back
into auto-commit state. If you wish to immediately start another
transaction, you will need to issue a separate -E<gt>begin call.

If a transaction exists at END-time as the process exits, it will be
automatically rolled back.

Returns true or throws an exception on error.

=head2 rollback_begin

  Foo::Bar->begin;
  
  # Code for the first transaction...
  
  Foo::Bar->rollback_begin;
  
  # Code for the last transaction...
  
  Foo::Bar->commit;

By default, L<ORLite>-generated code uses opportunistic connections.

Every <select> you call results in a fresh L<DBI> C<connect>, and a
C<disconnect> occurs after query processing and before the data is
returned. Connections are B<only> held open indefinitely during a
transaction, with an immediate C<disconnect> after your C<commit>.

This makes ORLite very easy to use in an ad-hoc manner, but can have
performance implications.

While SQLite itself can handle 1000 connections per second, the repeated
destruction and repopulation of SQLite's data page caches between your
statements (or between transactions) can slow things down dramatically.

The C<rollback_begin> method is used to C<rollback> the current transaction
and immediately start a new transaction, without disconnecting from the
database.

Its exception behaviour and return value is identical to that of a plain
C<commit> call.

=head2 do

  Foo::Bar->do('insert into table (foo, bar) values (?, ?)', {},
      $foo_value,
      $bar_value,
  );

The C<do> method is a direct wrapper around the equivalent L<DBI> method,
but applied to the appropriate locally-provided connection or transaction.

It takes the same parameters and has the same return values and error
behaviour.

=head2 selectall_arrayref

The C<selectall_arrayref> method is a direct wrapper around the equivalent
L<DBI> method, but applied to the appropriate locally-provided connection
or transaction.

It takes the same parameters and has the same return values and error
behaviour.

=head2 selectall_hashref

The C<selectall_hashref> method is a direct wrapper around the equivalent
L<DBI> method, but applied to the appropriate locally-provided connection
or transaction.

It takes the same parameters and has the same return values and error
behaviour.

=head2 selectcol_arrayref

The C<selectcol_arrayref> method is a direct wrapper around the equivalent
L<DBI> method, but applied to the appropriate locally-provided connection
or transaction.

It takes the same parameters and has the same return values and error
behaviour.

=head2 selectrow_array

The C<selectrow_array> method is a direct wrapper around the equivalent
L<DBI> method, but applied to the appropriate locally-provided connection
or transaction.

It takes the same parameters and has the same return values and error
behaviour.

=head2 selectrow_arrayref

The C<selectrow_arrayref> method is a direct wrapper around the equivalent
L<DBI> method, but applied to the appropriate locally-provided connection
or transaction.

It takes the same parameters and has the same return values and error
behaviour.

=head2 selectrow_hashref

The C<selectrow_hashref> method is a direct wrapper around the equivalent
L<DBI> method, but applied to the appropriate locally-provided connection
or transaction.

It takes the same parameters and has the same return values and error
behaviour.

=head2 prepare

The C<prepare> method is a direct wrapper around the equivalent
L<DBI> method, but applied to the appropriate locally-provided connection
or transaction

It takes the same parameters and has the same return values and error
behaviour.

In general though, you should try to avoid the use of your own prepared
statements if possible, although this is only a recommendation and by
no means prohibited.

=head2 pragma

  # Get the user_version for the schema
  my $version = Foo::Bar->pragma('user_version');

The C<pragma> method provides a convenient method for fetching a pragma
for a datase. See the SQLite documentation for more details.

=head1 TABLE PACKAGE METHODS

The example root package Foo::Bar::TableName is used in any examples.

B<TO BE COMPLETED>

=head1 TO DO

- Support for intuiting reverse relations from foreign keys

- Document the 'create' and 'table' params

=head1 SUPPORT

Bugs should be reported via the CPAN bug tracker at

L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=ORLite>

For other issues, contact the author.

=head1 AUTHOR

Adam Kennedy E<lt>adamk@cpan.orgE<gt>

=head1 SEE ALSO

L<ORLite::Mirror>, L<ORLite::Migrate>

=head1 COPYRIGHT

Copyright 2008 - 2010 Adam Kennedy.

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=cut
