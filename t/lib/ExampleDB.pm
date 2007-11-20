package ExampleDB;
use strict;
use warnings;
our $VERSION = (qw('$Rev: 16 $'))[1];
our $ID = '$Id: ExampleDB.pm 16 2007-11-20 19:16:29Z jason $';
use base qw( DBIx::Class::Schema );

__PACKAGE__->load_namespaces;

1;
