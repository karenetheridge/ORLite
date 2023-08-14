package LocalTest;

use strict;
use Exporter     ();
use ORLite       ();
use Test::More   ();
use File::Remove ();
use File::Spec::Functions ':ALL';
use File::Temp ();

our @ISA = qw(Exporter);
our @EXPORT = qw( test_db connect_ok create_ok );
our $VERSION = '2.00';


#####################################################################
# Test Methods

my %to_delete = ();
END {
    foreach my $file ( sort keys %to_delete ) {
        File::Remove::remove($file);
    }
}

sub test_db {
    my $file = catfile( @_ ? @_ : File::Temp::tempdir( 'ORLite-test-XXXXXX', TMPDIR => 1, CLEANUP => 1 ), 'sqlite.db' );
    unlink $file if -f $file;
    $to_delete{$file} = 1;
    return $file;
}

sub connect_ok {
    my $dbh = DBI->connect(@_);
    Test::More::isa_ok( $dbh, 'DBI::db' );
    return $dbh;
}

sub create_ok {
    my %param = @_;

    # Read the create script
    my $file = $param{file};
    local *FILE;
    local $/ = undef;
    open( FILE, $file )          or die "open: $!";
    defined(my $buffer = <FILE>) or die "readline: $!";
    close( FILE )                or die "close: $!";

    # Get a database connection
    my $dbh = connect_ok( @{$param{connect}} );

    # Create the tables
    my @statements = split( /\s*;\s*/, $buffer );
    foreach my $statement ( @statements ) {
        # Test::More::diag( "\n$statement" );
        $dbh->do($statement);
    }

    # Set the user_version if needed
    if ( $param{user_version} ) {
        $dbh->do("pragma user_version = $param{user_version}");
    }

    return $dbh;
}

1;
