use inc::Module::Install;

name 'DBICx-AutoDoc';
all_from 'lib/DBICx/AutoDoc.pm';

requires 'DBIx::Class';
requires 'Template';
requires 'Class::Inspector';
requires 'Carp';
requires 'Class::Accessor::Grouped';
requires 'FindBin';
requires 'Data::Dump';
requires 'File::Temp';
requires 'Pod::Usage';
requires 'Getopt::Long';

build_requires 'Test::More';

install_script 'dbicx-autodoc';
install_share 'templates';

auto_install;
WriteAll;
