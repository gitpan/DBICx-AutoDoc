use inc::Module::Install;

name 'DBICx-AutoDoc';
all_from 'lib/DBICx/AutoDoc.pm';

requires 'DBIx::Class';
requires 'File::ShareDir';
requires 'Template';

build_requires 'Test::More';

install_script 'dbicx-autodoc';

auto_install;
WriteAll;

install_share 'templates';
