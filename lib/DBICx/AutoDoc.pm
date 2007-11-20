package DBICx::AutoDoc;
use strict;
use warnings;
our $VERSION = '0.02';
use base qw( Class::Accessor::Grouped );
use Carp qw( croak );
use Template;
use Class::Inspector;
use FindBin qw( );
use Data::Dump qw( dump );
use DBICx::AutoDoc::Magic;
use File::Temp qw( tempfile );

__PACKAGE__->mk_group_accessors( simple => qw(
    output connect dsn user pass
) );
__PACKAGE__->mk_group_accessors( inherited => qw(
    include_path graphviz_command
) );
__PACKAGE__->include_path( __PACKAGE__->default_include_path() );
__PACKAGE__->graphviz_command( [ "fdp" ] );

sub new {
    my $self = bless( {
        output          => '.',
        connect         => 0,
    }, shift() );
    my %args = @_;

    for my $key ( keys %args ) { $self->$key( $args{ $key } ) }

    return $self;
}

sub schema {
    my ( $self, $val ) = @_;

    if ( $val ) {
        $self->{ 'schema' } = $val;
        eval "require $val";
        if ( $@ ) { croak "Could not load $val: $@" }
    } elsif( my $schema = $self->{ 'schema' } ) {
        if ( ref( $schema ) || ! $self->connect ) { return $schema }
        return $self->{ 'schema' } = $schema->connect(
            $self->dsn, $self->user, $self->pass,
        );
    } else {
        croak "No schema provided";
    }
}

sub schema_class {
    my ( $self ) = @_;

    my $schema = $self->schema;
    return ref( $schema ) || $schema;
}

sub schema_version { shift->schema->VERSION }

sub generated {
    my ( $self ) = @_;

    $self->{ 'generated' } ||= localtime;
    return $self->{ 'generated' };
}

sub software_versions {
    my ( $self ) = @_;

    return {
        map { ( $_ => $_->VERSION ) } qw(
            DBICx::AutoDoc DBICx::AutoDoc::Magic
            DBIx::Class Template
        )
    };
}

sub sources {
    my ( $self ) = @_;

    if ( $self->{ 'sources' } ) { return $self->{ 'sources' } }

    my $schema = $self->schema;

    my @sources = ();
    $self->{ 'sources' } = \@sources;

    for my $moniker ( sort $schema->sources ) {
        my $rs = $schema->resultset( $moniker );
        my $cl = $rs->result_class;

        # COLLECTING DATA
        push( @sources, {
            moniker             => $moniker,
            simple_moniker      => $self->get_simple_moniker_for( $moniker ),
            class               => $cl,
            primary_columns     => [ $cl->primary_columns ],
            table               => $cl->table,
            result_class        => $cl,
            resultset_class     => $cl->resultset_class,
            columns             => [ $self->get_columns_for( $cl ) ],
            unique_constraints  => [ $self->get_unique_constraints_for( $cl ) ],
            relationships       => [ $self->get_relationships_for( $cl ) ],
        } );
    }

    return $self->{ 'sources' };
}

sub inheritance {
    my ( $self, @classes ) = @_;

    if ( ! @classes ) {
        @classes = ( map { $_->{ 'class' } } @{ $self->sources } );
    }
    my %parents = ();
    while ( @classes ) {
        my $class = shift( @classes );
        next if $parents{ $class };
        my @tmp = do { no strict 'refs'; @{ $class.'::ISA' } };
        push( @classes, @tmp );
        $parents{ $class } = \@tmp;
    }
    return \%parents;
}

sub get_columns_for {
    my ( $self, $class ) = @_;

    use Tie::IxHash;

    my %cols = ();
    tie( %cols, 'Tie::IxHash' );

    # COLUMNS
    for ( $class->columns ) {
        my $col = $class->column_info( $_ );
        $col->{ 'name' } = $_;
        $col->{ 'is_inflated' } = delete $col->{ '_inflate_info' } ? 1 : 0;
        $cols{ $_ } = $col;
    }

    # PRIMARY COLUMNS
    for my $c ( $class->primary_columns ) {
        $cols{ $c }->{ 'is_primary' } = 1;
    }

    # UNIQUE CONSTRAINTS
    my %tmp = $class->unique_constraints;
    while ( my ( $key, $val ) = each %tmp ) {
        for my $x ( @{ $val } ) {
            push( @{ $cols{ $x }->{ 'unique_constraints' } }, $key );
        }
    }

    return values %cols;
}

sub get_unique_constraints_for {
    my ( $self, $class ) = @_;

    # UNIQUE CONSTRAINTS
    my $unique = {};

    my %tmp = $class->unique_constraints;
    for my $key ( sort keys %tmp ) {
        $unique->{ $key }->{ 'name' } = $key;
        my @tmp = @{ $tmp{ $key } };

        $unique->{ $key }->{ 'columns' } = \@tmp;
    }

    return $unique;
}

sub get_relationships_for {
    my ( $self, $class ) = @_;

    my %relationships = ();

    # RELATIONSHIPS (from DBICx::AutoDoc::Magic)
    unless ( $class->can( '_autodoc' ) ) {
        croak "$class cannot _autodoc, something must have gone wrong";
    }

    my $ad = $class->_autodoc || {};
    for ( @{ $ad->{ 'relationships' } || [] } ) {
        my ( $type, $relname, @parts ) = @{ $_ };
        my $rel = ( $relationships{ $relname } ||= {} );
        @{ $rel }{qw( name type )} = ( $relname, $type );

        if ( $type eq 'many_to_many' ) {
            @{ $rel }{qw( link_rel_name foreign_rel_name attributes )} = @parts;
        } else {
            @{ $rel }{qw( foreign_class condition attributes )} = @parts;
        }
    }

    # RELATIONSHIPS (from DBIx::Class::Relationship)
    for my $name ( $class->relationships ) {
        my $rel = ( $relationships{ $name } ||= {} );
        my $info = $class->relationship_info( $name );
        $rel->{ 'name' } ||= $name;
        for my $key ( keys %{ $info } ) {
            $rel->{ $key } = $info->{ $key };
        }
    }

    # GENERAL RELATIONSHIP MUNGING
    for my $name ( keys %relationships ) {
        my $rel = $relationships{ $name };
        for my $x ( '', 'foreign_' ) {
            if ( $rel->{ $x.'class' } ) {
                $rel->{ $x.'moniker' } = $rel->{ $x.'class' }->source_name;
            }
        }
    }

    return values %relationships;
}

sub relationship_map {
    my ( $self ) = @_;

    my @relmap = ();
    for my $source ( @{ $self->sources } ) {
        for my $rel ( @{ $source->{ 'relationships' } } ) {
            my $type = $rel->{ 'type' };
            my $map = {
                name    => $rel->{ 'name' },
                type    => $type,
            };
            push( @relmap, $map );
            if ( $type eq 'many_to_many' ) {
                for my $x (qw( link_rel_name foreign_rel_name )) {
                    $map->{ $x } = $rel->{ $x };
                }
                $map->{ 'accessor' } = 'many_to_many';
            } else {
                $map->{ 'accessor' } = $rel->{ 'attr' }->{ 'accessor' };
                $map->{ 'self' } = $source->{ 'moniker' };
                $map->{ 'foreign' } = $rel->{ 'foreign_class' }->source_name;

                my %cond = %{ $rel->{ 'cond' } };
            
                my @cond = ();
                while ( my ( $l, $r ) = each %cond ) {
                    push( @cond, { split( '\.', $l, 2 ), split( '\.', $r ) } );
                }
                $map->{ 'cond' } = \@cond;
            }
        }
    }
    return \@relmap;
}

sub get_simple_moniker_for {
    my ( $self, $moniker ) = @_;

    #if ( $moniker->can( 'source_name' ) ) { $moniker = $moniker->source_name }

    $self->{ '_simple_moniker_cache' } ||= {};
    my $cache = $self->{ '_simple_moniker_cache' };
    
    if ( $cache->{ $moniker } ) { return $cache->{ $moniker } }

    my $simple = $moniker;
    $simple =~ s/\W+/_/g;

    my %inverse_cache = reverse %{ $cache };
    if ( $inverse_cache{ $simple } ) {
        my $i = 0;
        while ( $inverse_cache{ $simple.$i } ) { $i++ }
        $simple .= $i;
    }

    $cache->{ $moniker } = $simple;
}

sub byname($$) { return shift->{ 'name' } cmp shift->{ 'name' } }

sub get_vars {
    my ( $self ) = @_;

    my @vars = qw(
        schema schema_class schema_version generated software_versions sources
        relationship_map filename_base output connect dsn user
        graphviz_command inheritance
    );

    $self->{ '_vars' } ||= {
        autodoc         => $self,
        dumper          => sub { return dump( @_ ) },
        simplify        => sub { return $self->get_simple_moniker_for( @_ ) },
        output_filename => sub { return $self->output_filename( @_ ) },
        ENV             => \%ENV,
        varlist         => [ @vars, 'ENV' ],
        ( map { ( $_ => $self->$_() ) } @vars ),
    };
    return $self->{ '_vars' };
}

sub find_template_file {
    my ( $self, $template ) = @_;

    my $path = $self->include_path;
    if ( ! ref $path ) { $path = [ $path ] }

    for my $x ( @{ $path } ) {
        my $test = File::Spec->catfile( $x, $template );
        if ( -f $test ) { return $test }
    }

    return;
}

sub fill_template {
    my ( $self, $template ) = @_;

    my $first_line = sub {
        open( my $fh, shift() ); chomp( my $start = <$fh> ); close( $fh );
        return $start;
    };

    my $tmpl = Template->new( { INCLUDE_PATH => $self->include_path } );
    my $outfile = $self->output_filename( $template, 1 );
    my $vars = $self->get_vars;

    if ( $first_line->( $self->find_template_file( $template ) ) =~ /^#!/ ) {
        my ( undef, $file ) = tempfile();
        my $script = $outfile.'.script';
        $tmpl->process( $template, $vars, $script ) || croak $tmpl->error;

        my $cmd = $first_line->( $script );
        $cmd =~ s/^#!//;

        open( my $outfh, '>', $outfile );
        open( my $infh, '-|', $cmd, $script );
        $outfh->print( <$infh> );
        close( $infh );
        close( $outfh );
        unlink( $script );
    } else {
        $tmpl->process( $template, $vars, $outfile ) || croak $tmpl->error;
    }
}

sub filename_base {
    my ( $self ) = @_;

    my $name = ref( $self->schema ) || $self->schema;
    if ( ! $name ) { croak "Cannot call filename_base without a schema" }
    $name =~ s/::/-/g;
    return join( '-', $name, $self->schema->VERSION || 1 );
}

sub output_filename {
    my ( $self, $template, $full ) = @_;

    my $base = $self->filename_base;
    $template =~ s/^AUTODOC/$base/;
    if ( $full ) {
        return $template;
    } else {
        return File::Spec->catfile( $self->output, $template );
    }
}

sub default_include_path {
    my ( $self ) = @_;
    my $class = ref( $self ) || $self;
    my $short = Class::Inspector->filename( $class );
    my $long = Class::Inspector->loaded_filename( $class );
    substr( $short, -3, 3, '' );
    $long =~ m{^(.*)\Q$short\E\.pm\z}s or die "Failed to find base dir";
    my $dir = File::Spec->catdir( $1, 'auto', $short );
    return [ $dir, File::Spec->catdir( $FindBin::Bin, "templates" ) ];
}

sub list_templates {
    my ( $self ) = @_;

    my $inc = $self->include_path;
    if ( ! ref $inc ) { $inc = [ $inc ] }
    my %tmpls = ();
    for my $dir ( @{ $inc } ) {
        opendir( my $dirfh, $dir );
        for ( readdir( $dirfh ) ) {
            next unless /^AUTODOC/;
            $tmpls{ $_ } = 1;
        }
        closedir( $dirfh );
    }

    return sort { length( $a ) <=> length( $b ) || $a cmp $b } keys %tmpls;
}

sub fill_all_templates {
    my ( $self ) = @_;

    $self->fill_templates( $self->list_templates );
}

sub fill_templates {
    my ( $self, @templates ) = @_;

    $self->fill_template( $_ ) for @templates;
}


1;
__END__

=head1 NAME

DBICx::AutoDoc - Generate automatic documentation of DBIx::Class::Schema objects

=head1 SYNOPSIS

The recommended way to use this package is with the command-line tool
L<dbicx-autodoc>.  You should check it's documentation for more details.

  use DBICx:::AutoDoc;
  
  my $ad = DBICx:::AutoDoc->new(
    schema  => 'MyApp::DB',
    output  => '/tmp',
  );
  $ad->fill_template( 'html' );

=head1 DESCRIPTION

DBICx::AutoDoc is a utility that can automatically generate
documentation for your L<DBIx::Class> schemas.  It works by collecting
information from several sources and arranging it into a format that makes
it easier to deal with from templates.

=head1 CONFIGURATION METHODS

=head2 new( %configuration )

Create a new L<DBICx::AutoDoc> object.  Most of the methods below can
also be passed to the constructor as configuration options.  Which means that
these two techniques are identical:

  # pass options to constructor
  my $ad = DBICx::AutoDoc->new( schema => 'MyApp::DB' );
  
  # create object, then configure it
  my $ad = DBICx::AutoDoc->new();
  $ad->schema( 'MyApp::DB' );

=head2 schema( $schema );

Retrieve or set the class name of the L<DBIx::Class::Schema> class you want
to document.

=head2 output( $directory );

Retrieve or change the directory where the generated documentation will be
placed.  This directory will be created for you if it doesn't exist.  The
default is to put the output files in the current directory.

=head2 connect( $true_or_false);

The connect method allows you to specify whether an attempt will be made
to connect to the actual database.  If given a false value (the default)
the documentation will be generated from only the code of your packages.
If true, then C<$schema->connect> will be called before the documentation
process begins (which means you may also have to set the L</dsn>, L</user>
and/or L</pass> options.)

The default is not to attempt to connect, which gives you documentation of
the classes, rather than the database itself.

Note that there are several parts of the documentation which may change,
depending on whether you are connected or not, as some parts of your code
may get modified by the database.  As an example, when deploying to a
PostgreSQL database, you might specify the data_type for your columns as
'varchar', but if you use the L</connect> option, then the value reported
by the database will probably be 'character varying' instead.

=head2 dsn( $dsn );

Retrieve or change the DSN for the database.  Might be included in the
documenation (some templates display this value, some don't) but if
L</connect> is false, then it won't be used for anything other than
displaying in the documentation.

=head2 user( $username );

Get or set the username used to connect to the database.  Ignored if
L</connect> is false.

=head2 pass( $password );

Get or set the password used to connect to the database.  Ignored if
L</connect> is false.

=head2 include_path( $scalar_or_array_ref );

Get or set the value passed to L<Template>'s INCLUDE_PATH option.  Unless
you are making your own templates, you probably don't need to change this.

The default is to look in the L<DBICx::AutoDoc> 'auto' directory,
which is where they get installed by L<Module::Install>, and if not found
there, to look in C<$FindBin::Bin/templates>, which allows you to use the
L<dbicx-autodoc> tool from an uninstalled copy of the package.

=head1 METHODS

=head2 filename_base

Returns a base filename for the output files.  By default this is based on
the class name and version number of your schema.  For example, if you schema
looks like this:

  package MyApp::DB::Schema;
  use base qw( DBIx::Class::Schema );
  our $VERSION = 42;

Then filename_base will return 'MyApp-DB-Schema-42'.

When a template is processed, the extension for the template is appended to
the output from this method to determine the output filename.

=head2 output_filename( $extension );

Given an extension, this method returns the filename that should be used for
storing the output of the template associated with that extension.  For
example, using the previous example schema, if C<output_filename( 'html' )> is
called, it would return 'MyApp-DB-Schema-42.html'.  When processing a template,
this filename will be created in the directory specified by the L</output>
option.

=head2 fill_template( $extension );

The C<fill_template> method takes an argument of the file extension (which
is also the template name) and renders that template into an appropriately
named file in the output directory.

=head2 fill_templates( @templates );

This is simply a convenience method that calls L<fill_template> for each of
the templates indicated.

=head2 fill_all_templates

Calling the C<fill_all_templates> method is simply a convenience wrapper that
calls L</list_templates> to determine what templates are available, and then
calls L</fill_template> for each one in turn, thereby generating all the
possible documentation for your schema.

=head2 list_templates

Returns a list of all the templates that are found in the L</include_path>.
Names from this list can be passed to L</fill_template> to genrate that
documentation.

=head1 INTERNAL METHODS

These methods are generally used only internally, but are documented for
completeness.

=head2 byname

A sort routine for sorting an array of hashrefs by the 'name' key.

=head2 default_include_path

A class method that calculates and returns the default value for the
include_path.

=head1 TEMPLATES

The templates used by this module are processed with the L<Template> package.
The template filename is the extension the output file should have, with a
C<.tt2> extension of it's own.  Only templates in the top level of directories
in the template search path will be turned into documentation files,
subcomponents used by the top-level templates can be placed in subdirectories
without worrying about whether their extensions conflict or not.

=head2 INCLUDED TEMPLATES

Templates included with the distribution are:

=head3 html

Generates an html page that documents each classes table name, column
information, keys and relationships.

=head3 dot

Generates a .dot file which can be used by L<GraphViz|http://www.graphviz.org/>
to generate a diagram of the relationships between the classes.  In order to
get a graphic from the dot file, you need to run one of the graphing commands
from the GraphViz package (I recommend 'fdp'), something like this:

  fdp -Tpng -o MyApp-DB-Schema-42.png MyApp-DB-Schema-42.dot

=head3 dot_post

This template doesn't actually produce any output itself, instead it runs
fdp for you to produce .png and .imap files from your .dot source.

=head3 dump

This is a very simple template that just gets the generated data structure
dumped using L<Data::Dump>.  The output is useful if you are creating your
own templates, as you can use it to see what data has been collected from
your schema, but if you are not creating templates then it isn't all that
valuable.

=head1 KNOWN BUGS / LIMITATIONS

These are the known bugs and/or limitations in the current version of this
package.

=head2 Not Windows compatible?

There are probably some windows-incompatibilities in the code, I've tried
to keep everything portable, but I'd be surprised if it works on Windows
on the first try.  Patches welcome.

=head2 Having problems with GraphViz and fonts?

If you get an error from fdp that says something like:

  Error: Could not find/open font : Times-Roman

Then you probably need to do the following:

=over 4

=item Locate a truetype font on your system to use (or download one)

  [jason@critter ~ 0]$ locate .ttf
  ...
  /Library/Fonts/Arial.ttf
  ...

=item Add a -Gfontpath option with the directory to the font

  fdp -Gfontpath="/Library/Fonts" (other options from above)

=item Add fontname options for the Graph as well as for Nodes and Edges

  -Gfontname=Arial -Nfontname=Arial -Efontname=Arial

=item So your final command line looks something like this:

  fdp -Gfontpath=/Library/Fonts -Gfontname=Arial \
    -Nfontname=Arial -Efontname=Arial

Then use this value as the c<--graphviz-command> option to L<dbicx-autodoc>,
or as the C<graphviz_command> option to L<DBICx::AutoDoc>.

  % dbicx-autodoc --schema=MyApp::DB --graphviz-command='fdp \
    -Gfontpath=/Library/Fonts -Gfontname=Arial -Nfontname=Arial \
    -Efontname=Arial' --output=./docs

=back

=head1 SEE ALSO

L<dbicx-autodoc>, L<DBICx::AutoDoc>, L<DBIx::Class>, L<DBIx::Class::Schema>,
L<Template>

=head1 AUTHOR

Jason Kohles, E<lt>email@jasonkohles.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 by Jason Kohles

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
