package ExampleDB::Result::Person;
use strict;
use warnings;
our $VERSION = (qw('$Rev: 16 $'))[1];
our $ID = '$Id: Person.pm 16 2007-11-20 19:16:29Z jason $';
use base qw( DBIx::Class );

__PACKAGE__->load_components(qw( InflateColumn::DateTime Core ));

__PACKAGE__->table( 'people' );
__PACKAGE__->add_columns(
    id          => {
        data_type           => 'integer',
        is_nullable         => 0,
        is_auto_increment   => 1,
    },
    name        => {
        data_type           => 'varchar',
        size                => 64,
        is_nullable         => 0,
    },
    username    => {
        data_type           => 'varchar',
        size                => 16,
        is_nullable         => 1,
    },
    birthdate   => {
        data_type           => 'date',
    },
);
__PACKAGE__->set_primary_key( 'id' );
__PACKAGE__->add_unique_constraint( [ qw( username ) ] );

my @has = (
    phone_numbers   => 'PhoneNumber',
    addresses       => 'Address',
    emails          => 'EmailAddress',
);
while ( @has ) {
    my ( $accessor, $name ) = splice( @has, 0, 2 );
    __PACKAGE__->has_many( $accessor, "ExampleDB::Result::$name", 'person_id' );
}

1;
