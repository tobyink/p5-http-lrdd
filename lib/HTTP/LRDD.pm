#!/usr/bin/perl

=head1 NAME

HTTP::LRDD - link-based resource descriptor discovery

=head1 SYNOPSIS

 use HTTP::LRDD;
 
 my $lrdd        = HTTP::LRDD->new;
 my @descriptors = $lrdd->discover($resource);

or 

 use HTTP::LRDD;
 my @descriptors = HTTP::LRDD->discover($resource);

=cut

package HTTP::LRDD;

use strict;
use 5.008;

use HTML::HTML5::Parser;
use HTML::HTML5::Sanity;
use HTTP::Link::Parser qw(:all);
use HTTP::Status qw(:constants);
use RDF::RDFa::Parser '0.30';
use RDF::TrineShortcuts;
use URI;
use URI::Escape;
use XML::Atom::OWL;
use XRD::Parser;

=head1 VERSION

0.01

=cut

our $VERSION = '0.01';
my (@Predicates, @MediaTypes);

BEGIN
{
	@Predicates = qw(describedby lrdd http://www.w3.org/1999/xhtml/vocab#meta http://www.w3.org/2000/01/rdf-schema#seeAlso);
	@MediaTypes = qw(application/xrd+xml application/rdf+xml text/turtle application/atom+xml;q=0.9 application/xhtml+xml;q=0.9 text/html;q=0.9 */*;q=0.1)
}

=head1 DESCRIPTION

=head2 Import Routine

=over 4

=item C<< use HTTP::LRDD (@predicates); >>

When importing HTTP::LRDD, you can optionally provide a list of
predicate URIs (i.e. the URIs which rel values expand to). This
may also include IANA-registered link types, which are short tokens
rather than full URIs.

If you do not provide a list of predicate URIs, then a sensible
default set is used.

=back

=cut

sub import
{
	my $class   = shift;
	@Predicates = @_ if @_;
}

=head2 Constructors

=over 4

=item C<< HTTP::LRDD->new(@predicates); >>

Create a new LRDD discovery object using the given predicate URIs.
If @predicates is omitted, then the predicates passed to the import
routine are used instead.

=cut

sub new
{
	my $class   = shift;
	my $self    = bless { }, $class;
	
	$self->{'predicates'} = @_ ? \@_ : \@Predicates;
	
	$self->{'ua'} = LWP::UserAgent->new;
	$self->_ua->agent(sprintf('%s/%s ', __PACKAGE__, $VERSION));
	$self->_ua->default_header('Accept' => (join ', ', @MediaTypes));
	$self->_ua->max_redirect(0);
	
	return $self;
}

=item C<< HTTP::LRDD->new_strict(@predicates); >>

Create a new LRDD discovery object using the 'describedby' and
'lrdd' IANA-registered predicates.

=cut

sub new_strict
{
	my $class   = shift;
	return $class->new(qw(describedby lrdd));
}

=item C<< HTTP::LRDD->new_default(@predicates); >>

Create a new LRDD discovery object using the default set of
predicates ('describedby', 'lrdd', 'xhv:meta' and 'rdfs:seeAlso').

=back

=cut

sub new_default
{
	my $class   = shift;
	return $class->new(qw(describedby lrdd http://www.w3.org/1999/xhtml/vocab#meta http://www.w3.org/2000/01/rdf-schema#seeAlso));
}

=head2 Public Method

=over 4

=item C<< $lrdd->discover($uri) >>

Discovers a descriptor for the given URI; or if called in a list
context, a list of descriptors.

A descriptor is a resource that provides a description for something.
So, if the given URI was the web address for an image, then the
descriptor might be the web address for a metadata file about the
image. If the given URI was an e-mail address, then the descriptor
might be a profile document for the person to whom the address
belongs.

There is no guaranteed file format for the descriptor, but it is
often RDF, POWDER XML or XRD.

This method can also be called without an object (as a class
method) in which case, a temporary object is created automatically
using C<< new >>.

=back

=cut

sub discover
{
	my $self = shift;
	my $uri  = shift;
	my $list = wantarray;
	
	$self = $self->new( @Predicates )
		unless ref $self;

	my $model    = rdf_parse();
	my $response = $self->_ua->head($uri);
	
	# Parse HTTP 'Link' headers.
	parse_links_into_model($response, $model);
	
	if ($response->code eq HTTP_SEE_OTHER) # 303 Redirect
	{
		my $seeother = URI->new_abs(
			$response->header('Location'),
			URI->new($uri));
		
		$model->add_hashref({
			$uri => {
				'http://www.w3.org/2000/01/rdf-schema#seeAlso' => [
						{ 'value' => "$seeother" , 'type' => 'uri' },
					],
				},
			});
	}
	
	# Parse as RDFa, if the response is RDFa.
	($response, my $rdfa) = $self->_process_rdfa($response, $model, $uri);
	
	# If the response was not RDFa, try parsing as RDF.
	($response, my $rdfx) = $self->_process_rdf($response, $model, $uri)
		unless defined $rdfa;
		
	my @results;
	
	my @p;
	foreach my $p (@{ $self->{'predicates'} })
	{
		push @p, sprintf('{ <%s> <%s> ?descriptor . }',
			$uri, HTTP::Link::Parser::relationship_uri($p));
	}
	my $sparql = $list ?
		'SELECT DISTINCT ?descriptor WHERE { '.(join ' UNION ', @p).' }' :
		'SELECT DISTINCT ?descriptor WHERE { OPTIONAL '.(join ' OPTIONAL ', @p).' }';
		
	my $iterator = rdf_query($sparql, $model);
	while (my $row = $iterator->next)
	{
		push @results, $row->{'descriptor'}->uri
			if defined $row->{'descriptor'}
			&& $row->{'descriptor'}->is_resource;
	}
	if (@results)
	{
		return $list ? @results : $results[0];
	}
	
	# No results. That's bad news. As a last ditch attempt, try host-meta.
	my $hostmeta = XRD::Parser->hostmeta($uri);
	$hostmeta->consume;

	# First try original query.
	$iterator = rdf_query($sparql, $hostmeta->graph);
	while (my $row = $iterator->next)
	{
		push @results, $row->{'descriptor'}->uri
			if defined $row->{'descriptor'}
			&& $row->{'descriptor'}->is_resource;
	}
	if (@results)
	{
		return $list ? @results : $results[0];
	}

	# Then try using host-meta URI templates.
	my $hosturi = XRD::Parser->URI_HOST . URI->new($uri)->host;
	@p = ();
	foreach my $p (@{ $self->{'predicates'} })
	{
		push @p, sprintf('{ <%s> <%s%s> ?descriptor . }',
			$hosturi, XRD::Parser->SCHEME_TMPL, HTTP::Link::Parser::relationship_uri($p));
	}
	$sparql = $list ?
		'SELECT DISTINCT ?descriptor WHERE { '.(join ' UNION ', @p).' }' :
		'SELECT DISTINCT ?descriptor WHERE { OPTIONAL '.(join ' OPTIONAL ', @p).' }';

	$iterator = rdf_query($sparql, $hostmeta->graph);
	while (my $row = $iterator->next)
	{
		if (defined $row->{'descriptor'}
		&&  $row->{'descriptor'}->is_literal
		&&  $row->{'descriptor'}->literal_datatype eq (XRD::Parser->URI_XRD.'URITemplate'))
		{
			my $u = $row->{'descriptor'}->literal_value;
			$u =~ s/\{uri\}/uri_escape($uri)/ie;
			push @results, $u;
		}
	}
	if (@results)
	{
		return $list ? @results : $results[0];
	}

	# Argh! - well, at least the URI itself was in a format capable
	# of providing some metadata.
	if ($rdfa || $rdfx)
	{
		return $list ? ($uri) : $uri;
	}
	
	return undef;
}


sub _process_rdfa
{
	my ($self, $response, $model, $uri) = @_;
	
	my $rdfa_options;
	my $rdfa_input;
	
	if ($response->content_type =~ m'^(application/atom\+xml|image/svg\+xml|application/xhtml\+xml|text/html)'i)
	{
		$self->_ua->max_redirect(3);
		$response = $self->_ua->get($uri);
		$self->_ua->max_redirect(0);
	}
	else
	{
		return ($response, undef);
	}
	
	if ($response->content_type =~ m'^application/atom\+xml'i)
	{
		$rdfa_options = RDF::RDFa::Parser::OPTS_ATOM;
		$rdfa_options->{'atom_parser'} = 1;
	}
	elsif ($response->content_type =~ m'^image/svg\+xml'i)
	{
		$rdfa_options = RDF::RDFa::Parser::OPTS_SVG;
	}
	elsif ($response->content_type =~ m'^application/xhtml\+xml'i)
	{
		$rdfa_options = RDF::RDFa::Parser::OPTS_XHTML;
	}
	elsif ($response->content_type =~ m'^text/html'i)
	{
		$rdfa_options = RDF::RDFa::Parser::OPTS_HTML5;
		$rdfa_options = RDF::RDFa::Parser::OPTS_HTML4
			if $response->decoded_content =~ m'<!doctype\s+html\s+public\s+.-//W3C//DTD HTML 4'i;
		
		my $parser  = HTML::HTML5::Parser->new;
		$rdfa_input = $parser->parse_string($response->decoded_content);
	}
	
	if (defined $rdfa_options)
	{
		# Make sure any predicate keywords are recognised in @rel/@rev.
		# This can override some normal RDFa keywords in some cases.
		foreach my $attr (qw(rel rev))
		{
			foreach my $p (@{ $self->{'predicates'} })
			{
				$rdfa_options->{'keywords'}->{$attr}->{$p}
					= HTTP::Link::Parser::relationship_uri($p)
					unless $p =~ /:/;
			}
		}
		
		$rdfa_input = $response->decoded_content
			unless defined $rdfa_input;
		
		my $parser = RDF::RDFa::Parser->new($rdfa_input, $response->base, $rdfa_options, $model->_store);
		$parser->consume;
		return ($response, $rdfa_options);
	}
	
	return ($response, undef);
}

sub _process_rdf
{
	my ($self, $response, $model, $uri) = @_;
	my $type;
	
	if ($response->content_type =~ m'^(application/rdf\+xml|(application|text)/(x-)?(rdf\+)?(turtle|n3|json))'i)
	{
		$self->_ua->max_redirect(3);
		$response = $self->_ua->get($uri);
		$self->_ua->max_redirect(0);
		
		$type = 'Turtle';
		$type = 'RDFXML'  if $response->content_type =~ /rdf.xml/;
		$type = 'RDFJSON' if $response->content_type =~ /json/;
	}
	else
	{
		return ($response, undef);
	}
	
	rdf_parse($response->decoded_content, type=>$type, model=>$model, base=>$response->base);
	return ($response, 1);
}

sub _ua
{
	my $self = shift;
	return $self->{'ua'};
}

1;

=head1 BUGS

Please report any bugs to L<http://rt.cpan.org/>.

=head1 SEE ALSO

L<XRD::Parser>, L<WWW::Finger>, L<RDF::TrineShortcuts>.

L<http://www.perlrdf.org/>.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT

Copyright 2010 Toby Inkster

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
