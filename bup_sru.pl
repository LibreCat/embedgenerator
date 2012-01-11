#!/usr/bin/perl

=head1 bup_sru.pl

 Perl SRU client (related to a user GUI)
 for the LUP SRU server
 Analyzes and prepares LUP MODS for templating 
 Author: Friedrich Summann, started on Apr 24 2010
 Bielefeld University Library

=cut

use lib qw(../lib/extension ../lib/default);

use strict;
use warnings;

use CGI ;
use LWP::UserAgent;

use XML::Simple;
use Template;

use Encode ;
 
use URI::Escape;
use CSL ;
# use Config::Auto;

use luurCfg;                  # reading the PUB configuration
my $cfg = new luurCfg;

  ###### config part_entry

my $basic_url =  $cfg->{pub}->{basicurl} ;  # 'http://bup-dev.ub.uni-bielefeld.de/sru?version=1.1&operation=searchRetrieve' ;

# =======================================================================================

my $q = CGI::new();

my $func = $q->param('func') || 'smask' ;
my $ftyp = $q->param('ftyp') || '' ;
my $ttyp = $q->param('ttyp') || '' ;

my $tt = Template->new({ # Template object
   #    ENCODING => 'utf8',
       INCLUDE_PATH => '../tt_templates',
       COMPILE_DIR => '/tmp/ttc',
       STAT_TTL  => 60,
 #      INCLUDE_PATH => '/opt/devel/unibi/sbcat/tt_templates',
   }) ;

my $templ ;

# print_debug (\%ENV, 'ENV:') ;
 
my %templ_hash ;   # template variable hash

if (!($ftyp)){

   print "Content-type: text/html\n\n";
}
else {
       print "Content-type: text/plain\n\n";
  #    my $dat = time2str("%a, %e %b %Y %T GMT",time() + 18000);
  #    print "Expires: $dat\n\n";
}

my $addr = user_adress () ;

if ($addr =~ /$cfg->{pub}->{localip}/){

    $templ_hash{localuser} = 1 ;
}

if ($func eq 'smask'){  # display search mask tt

   $templ = 'bup_smask' ;
 
   if ($ttyp){
      $templ .= '_' . $ttyp ;
   }
   $templ .= '.tmpl' ;
                           # query Parameter zusammenstellen

   $tt->process($templ, \%templ_hash)   || die $tt->error;
   exit ()  ;
} 
elsif ($func eq 'embd') # display snippet generator
{
    $templ_hash{bisid} = $q->param('bisid') || '' ;
   
    $tt->process('bup_embed_js.tmpl', \%templ_hash)   || die $tt->error;
    exit ()  ;
}
elsif ($func eq 'drec'){ # display single record
 
    &display_record () ; 
    exit () ;
}
elsif ($func eq 'plst'){ # display publication list
    &display_publist () ;
    exit () ;
}


 my %query ;
 my %sru_args ;

         # firstly: the query parameters

 my $url_str = prepare_sru_query (\%query) ;

         # additional sru parameters (navigation)

 if ($q->param('maxrecs')){

      $sru_args{maximumRecords} = $q->param('maxrecs') ;
 }
 else { $sru_args{maximumRecords} = 10 ; }

 if ($q->param('startrecs')){

      $sru_args{startRecord} = $q->param('startrecs') + 1;
 }
 else { $sru_args{startRecord} = 1 ; } # 0 ; }

 
 if ($q->param('increcs')){         # overrule if necessary
    
      $sru_args{startRecord} = $q->param('increcs')
 }

 if ($q->param('sortby')){

      $query{sortby} = $q->param('sortby') ;
 }

 # add the sru params

 my $sru_str = '' ;

 foreach my $entry (keys %sru_args){
       
    $sru_str .= '&' . $entry . '=' . $sru_args{$entry} ;
 }

 $basic_url .= $sru_str . '&query=' ; 

    # create and add the entry 
 
 my $first_flag = 1 ;

 my $query_str ;
 my $freetext_tag ; 

 if (defined ($query{freetext})){

   print_debug ($query{freetext}, 'Fulltext-Query') ;

    if ($query{freetext} ne ''){

       $query_str = $freetext_tag =  $query{freetext} ;
       $first_flag = 0 ;
    }
    
   delete ($query{freetext}) ;
 }

 my $add_query_str ;  # for NOT operator to be added at the end of the query

 foreach my $entry (keys %query){
   
   my $op_char = '%3D' ;   #  allowing other ops than =
 
   if ($query{$entry} =~ /^(\<|\>)(.*)/){

         $op_char = '%' . uc(sprintf("%x", ord ($1))) ;
         $query{$entry} = $2 ;
   }    
   elsif ($query{$entry} =~ /^(NOT)?(%20all|%20any|%20exact)(.*)/){
        $op_char = $2 ;
        if ($1){ #  eq 'NOT'){
            $query{$entry} = 'NOT' . $3 ;
        }
        else {   $query{$entry} =  $3 ; }
   }

   if (!($first_flag)){

      if ($query{$entry} =~ /^NOT(.*)/){
      
             $query_str .= "%20NOT%20" ;
             $query{$entry} = $1 ;
      }
      else {
              $query_str .= '%20AND%20' ;
      }
      $query_str .= $entry .  $op_char . $query{$entry} ;
   }
   else {  # No boolean operator at the start

       if ($query{$entry} =~/^NOT(.*)/){

           $add_query_str = " NOT%20$entry$op_char$1" ; # keep the NOT for the added end
       }
       else {
                $query_str .= $entry . $op_char . $query{$entry}  ;
                $first_flag = 0 ;
       }
    }
 }

 if ($add_query_str){
 
    $query_str = $query_str . $add_query_str ;
 }


  $basic_url .=  $query_str  . '&sortKeys=publishingYear,,0' ; # default sorting descending publication year
 
  print_debug ($basic_url, 'SRU-Querystr:(search)') ;

  my $mods_response = process_sru_query ($basic_url) ;

      # analyze the MODS response

  #  print_debug ($mods_response, 'MODS-Response') ;

  my $xmlParser = new XML::Simple();
  my $xml = $xmlParser->XMLin($mods_response);

#  my $converter = Text::Iconv->new("UTF-8","UTF-8//IGNORE");
#  $xml = $converter->convert($xml);

  my $response_ref = extract_mods ($mods_response) ;

  $response_ref->{query} = \%query ; 
  if ($freetext_tag){

    $response_ref->{query}->{ftext} = $q->param('ftext') ; # $fulltext_tag ;
  }
  if ($q->param('author')){

    $response_ref->{query}->{author} =  $q->param('author') ; # rewrite the original format
  }
  if ($response_ref->{query}->{nonLu}){

      if ($response_ref->{query}->{nonLu} =~ /^NOT/){

         $response_ref->{query}->{nonLu} = '0' ;
      }
      else { $response_ref->{query}->{nonLu} = '1' ; } 
  }
  if ($response_ref->{query}->{fulltext}){

      if ($response_ref->{query}->{fulltext} =~ /^NOT/){

         $response_ref->{query}->{fulltext} = '0' ;
      }
      else { $response_ref->{query}->{fulltext} = '1' ; } 
  }

  $url_str .=  '&maxrecs=' . $sru_args{maximumRecords} ;

  $response_ref->{url_str} = $url_str ; # to allow navigation through the result set
  $response_ref->{numrecs} = $xml->{numberOfRecords} ;
  $response_ref->{startrecs} = $sru_args{startRecord} ;
  $response_ref->{currpos} = $response_ref->{startrecs} ; #  + 1;

    ## construct the nav bar array

  my  $max_entries = 20 ; ## fits into the screen

  my @nav_array ;

  my $j = 0 ;
  my $area = 5 ;
  my $range = $sru_args{maximumRecords} ;
  my $curr_pos =  $sru_args{startRecord} + 1 ;
  my $last_doc = int (($response_ref->{numrecs} - 1) / $sru_args{maximumRecords}) * $sru_args{maximumRecords} ; 
  my $doc_count = $response_ref->{numrecs} ;
  my $punktflag = 1 ;

  if ($doc_count == 0){
      $max_entries = 0 ;
  }

  $response_ref->{last_doc} = $last_doc;
  $response_ref->{range} = $range ;

  my $left_pos = int ($curr_pos / $range - 5) ;

  if ($left_pos < 0){ $left_pos = 0  ; }

  my $right_pos = int ($curr_pos /$range + 5) ;
  if ($right_pos * $range > $last_doc){

     $right_pos = int ($last_doc / $range) ;
  }
   
  foreach my $i ($left_pos..$right_pos){

     push (@nav_array, $i * $range + 1 ) ;
 }

  push (@{$response_ref->{nav_pos}} , @nav_array) ;
 
  # switch_record_utf8 ($response_ref) ;

  my $style = $cfg->{csl_engine}->{default_style} ; # 'plos' ; # 'pubfront' ;
  if ($q->param('style')){   
       
       $style = $q->param('style') ; # citation style for CSL processor
       $response_ref->{style} = $style ;
  }

  if ($style ne 'std'  &&  $response_ref->{numrecs}){

       my $csl = CSL->new ; 

       my $citation_ref = $csl->process ($style, $response_ref) ; #  create_csl ($style, 'text', $response_ref) ;

       my $i = 0 ;

       my %temp_hash ;

       foreach my $entry (@{$citation_ref})
       {
           $temp_hash{$entry->{id}} = $i++ ; 
       }

       foreach my $entry (@{$response_ref->{records}}){
           $entry->{citation} =  $citation_ref->[$temp_hash{$entry->{recordid}}]{citation} ;
           $entry->{sort_nr} = $temp_hash{$entry->{recordid}} ;
       }
  }

  $templ = 'bup_liste' ;
 
  if ($ttyp){
      $templ .= '_' . $ttyp ;
  }
  $templ .= '.tmpl' ;

  print_debug ($response_ref, 'Listen-Templ.:') ;
  $tt->process($templ,  $response_ref) || die $tt->error ; 
    
      # prepare  the template hash ,
 
  exit () ;

######## the default end of main 

=head2 display_record

  function which realizes the display of a single record

  Arguments: 

       - internal record id
=cut

sub display_record {

    my $id ;

    if ($q->param('id')){

      $id = $q->param('id')  ;
    }

    my $query_str = $basic_url . '&query=id%20exact%20%22' . $id . '%22' ;   # sru query for id

    my $mods_response = process_sru_query ($query_str) ;

    my $response_ref = extract_mods ($mods_response) ;

    $response_ref->{records}[0]{id} = $id ; 
    $response_ref->{localuser} = $templ_hash{localuser} ;

  #  switch_record_utf8 ($response_ref) ;

    if ($response_ref->{numrecs} > 0){

       $response_ref->{coins_str} = proc_coins ($response_ref->{records}[0]) ;

       my $style = $cfg->{csl_engine}->{default_style} ; # default citation style apa-like (realized internally)
       if ($q->param('style')){   
       
         $style = $q->param('style') ; # citation style for CSL processor
       }

       $response_ref->{style} = $style ;

       if ($style ne 'std'){

         my $csl = CSL->new () ;  # $style, $response_ref) ;
        
         my $citation_ref = $csl->process ($style, $response_ref)  ;

        $response_ref->{records}[0]{citation} = $citation_ref->[0]{citation} ;
       }
    }
    $templ = 'bup_record' ;
 
    if ($ttyp){
       $templ .= '_' . $ttyp ;
    }
    $templ .= '.tmpl' ;

    print_debug ($response_ref, 'Template-Var fuer drec') ;

    $tt->process($templ, $response_ref) || die $tt->error ; 
}

=head2 display_publist

  function which realizes the display of a publication list

=cut

sub display_publist {

    use Orms;

    my $o;

    my $aspect_str ;
    my ($author, $style_pref, $sort_pref) ;
    my $dept ;    

    my $hiddenlist_ref ;

    my $limit = 0 ; 
    if ($q->param('limit')){
        $limit = $q->param('limit') ;
    }

    if ($q->param('author')){

      $author = $q->param('author') ;
      $aspect_str = '_basic%20exact%20%22' . $author . '%22' ; # _basic searches all personal actors, author, editor

      if ($author =~ /^\d+$/){                # do only if a personNumber is used

         my $luur = Orms->new($cfg->{ormsCfg});

         foreach (qw(luAuthor personNumber)) {
            $o->{$_} = $luur->getObject($_);
         }

         my ($luAuthorOId) = @{$luur->getObjectsByAttributeValues(type => $o->{'luAuthor'}, attributeValues => {$o->{'personNumber'} => $author})} ;

        if ($luAuthorOId){

           $style_pref  = $luur->getAttributeValue(object => $luAuthorOId, attribute => 'citationStyle');
           $sort_pref =  $luur->getAttributeValue(object => $luAuthorOId, attribute => 'sortDirection');
																		    # fetching the hidden records
           $hiddenlist_ref = $luur->getRelatedObjects (object2 => $luAuthorOId, relation=>'isHiddenFor');
        }
      }
    }
    elsif ($q->param('dept')){

       $dept = $q->param('dept') ;
       $aspect_str = 'department=' . $dept  ;
    }
    else {
        return ;
    }
    if ($q->param('publyear')){

      $aspect_str .= 'AND%20PublishingYear' .  '%3D%22' . $q->param('publyear') .'%22' ;
    }
    if ($q->param('doctype')){

       $aspect_str .= 'AND%20' . 'documentType' . '%3D%22' . $q->param('doctype') . '%22' ;
    }

    my $query_str = $basic_url . '&maximumRecords=250&query=' . $aspect_str ;

    $query_str .= '&sortKeys=publishingYear,,0' ;

    print_debug ($query_str, 'SRU-Querystr(plst):') ;

    my $start_rec = 1 ;

    my $response_ref ; # the whole response
    @{$response_ref->{records}} = () ;

    my $range = 250 ; # switch to config

    while (1){  # paging the result

       my $temp_str = $query_str ;

       if ($start_rec > 1){

          $temp_str = $query_str . '&startRecord=' . $start_rec ; 
       }

       my $mods_response = process_sru_query ($temp_str) ;
    
       my $temp_ref ;

       if ($limit && $limit < $start_rec + $range){

            $temp_ref = extract_mods ($mods_response, $limit) ;
       }
       else {  # no limit for response
         
            $temp_ref = extract_mods ($mods_response) ;
       }

         #  switch_record_utf8 ($response_ref) ;
       
       if ($temp_ref->{numrecs} > 0){
          push (@{$response_ref->{records}}, @{$temp_ref->{records}}) ;
       }

       $response_ref ->{numrecs} += $temp_ref->{numrecs} ;

       # pushing the records 

       if ($start_rec + $range < $temp_ref->{numrecs}){

           $start_rec += $range ;
       }
       else {
          last 
       }    ; # currently only

     }       # while

       if ($author){   # regarding the specific author information
 
          $response_ref->{norm_author} = switch_author ($author) ;
          $response_ref->{list_author} = $author ;
 
       # ---- delete hidden publications 

       if ($hiddenlist_ref){

          my %id_hash ;
          foreach my $entry (@$hiddenlist_ref){  # building the id hash

              $id_hash{$entry} = 1 ;
          }
          my $index = 0 ;
          foreach my $entry (@{$response_ref->{records}}){

            if ($id_hash{$entry->{recordid}}){
              splice (@{$response_ref->{records}}, $index, 1) ;
            } 
            else { $index++ ; }
         }
      }
 # ---- delete hidden publications 
      }

    if ($dept){
        $response_ref->{list_dept} = $dept ;
    }
    
    my $sort_criteria = 'publ_year'  ; # default publication year
    my $sort_type = 'str' ;  # default string-type str (num)
    my $sort_order = 'desc' ; # default descending (asc)

    my $style = 'pub' ; # default citation style apa-like (realized internally)

                             # resuming the Author preferences from LUP if available
    if ($style_pref){ 
        $style = lc ($style_pref) ;
    }
    if ($sort_pref){
        $sort_order = lc ($sort_pref) ;
    }

   if ($q->param('sortt')){
       
       $sort_type = lc( $q->param('sortt')) ;
    }
    if ($q->param('sortc')){
       
       $sort_criteria = $q->param('sortc') ;

    }
    if ($q->param('sorto')){
       
       $sort_order = lc ($q->param('sorto')) ;
    }
    if ($q->param('style')){   
       
       $style = $q->param('style') ; # citation style for CSL processor
    }
          # now sort the records list if needed

    if ($response_ref->{numrecs} > 1){   # sorting only when necessary

       if ($sort_type eq 'num' && $sort_order eq 'desc'){

            @{$response_ref->{records}} = sort {

               if (ref ($a->{$sort_criteria}  eq 'ARRAY')){

                   $b->{$sort_criteria}[0] <=> $a->{$sort_criteria}[0] ;
               }
              else {

                   $b->{$sort_criteria} <=> $a->{$sort_criteria} ;
              }
            } @{$response_ref->{records}} ;    
      }
      elsif ($sort_type eq 'num' && $sort_order eq 'asc'){

         @{$response_ref->{records}} = sort { $a->{$sort_criteria} <=> $b->{$sort_criteria}} @{$response_ref->{records}} ;     
      }
      elsif ($sort_type eq 'str' && $sort_order eq 'asc'){

         if ($sort_criteria eq 'author'){

              @{$response_ref->{records}}  = map {$_->[1]}
                 
                 sort {$a->[0] cmp $b->[0]}
                 map {[$_->{author}[0]{full}, $_]}  @{$response_ref->{records}}  ;
         }
         elsif ($sort_criteria eq 'title'){
          
             @{$response_ref->{records}}  = map {$_->[1]}
                 
                 sort {$a->[0] cmp $b->[0]}
                 map {[$_->{title}[0], $_]}  @{$response_ref->{records}}  ;
         }
         else { @{$response_ref->{records}} =   sort {

                   $b->{$sort_criteria} cmp $a->{$sort_criteria} ;
              
            } @{$response_ref->{records}} ;    
         }
      }
     else {
         @{$response_ref->{records}} = sort { $b->{$sort_criteria} cmp $a->{$sort_criteria}} @{$response_ref->{records}} ;     
     }
   }

    $response_ref->{style} = $style ;

    my $templ = 'bup_publist' ;
    if ($ftyp){   # switched to csl processing
    
        $templ .= "_$ftyp" ; 

      if ($ftyp eq 'js'){

          foreach my $ref (@{$response_ref->{records}}){   # workaround for some problematic chars

             $ref->{title} =~ s /"/\\"/g ;
             $ref->{title} =~ s /'/\\'/g ;

             foreach my $entry (@{$ref->{relation}}){   # Titel in Gesamttitelangaben

                if ($entry->{title}){
 
                   $entry->{title} =~  s /"/\\"/g ;
                   $entry->{title} =~ s /'/\\'/g ;
                }
             }
          }
       }
    }

    if ($ttyp){
       $templ .= '_' . $ttyp ;
    }
    $templ .= '.tmpl' ;

    if ($style ne 'std'){  

       my $csl = CSL->new ($style, $response_ref) ;
        
       my $citation_ref = $csl->process ($style, $response_ref) ; #  ($style, 'text', $response_ref) ;

       # $response_ref->{records} = () ;

       my $i = 0 ;

       my %temp_hash ;

  #     foreach my $entry (@{$response_ref->{records}})

       foreach my $entry (@{$citation_ref})
       {
           $temp_hash{$entry->{id}} = $i++ ; 
       }

       foreach my $entry (@{$response_ref->{records}}){
           $entry->{citation} =  $citation_ref->[$temp_hash{$entry->{recordid}}]{citation} ;
           $entry->{sort_nr} = $temp_hash{$entry->{recordid}} ;
       }

              # now sort for the CSL order - based on sort_nr

       @{$response_ref->{records}} = sort { $a->{'sort_nr'}  <=>  $b->{'sort_nr'}} @{$response_ref->{records}}  ;

       my $stop = 1 ;

               # @{$response_ref->{records}} = sort { $b->{$sort_criteria} cmp $a->{$sort_criteria}} @{$response_ref->{records}} ;  
      #  $citation_ref->[0]{citation} ;
       # push  (@{$response_ref->{records}}, @$citation_ref) ;
    }
    else { # creating Template based citation -> CSL
 
        foreach my $ref (@{$response_ref->{records}}){   # workaround for some problematic chars

             foreach my $title_entry (@{$ref->{title}}){         

                $title_entry =~ s /"/\\"/g ;
                $title_entry =~ s /'/\\'/g ;
             }
        }
    #   switch_record_utf8 ($response_ref) ;
    } 

    $tt->process($templ, $response_ref) || die $tt->error ; 
}

=head2 process_sru_query

 process the REST SRU request via LWP

=cut

sub process_sru_query {

  my ($query_str) = @_ ;   

  my $my_ua = LWP::UserAgent->new();

  # prepare the HTTP client

  $my_ua->agent('Netscape/4.75');
  $my_ua->from('agent@ub.uni-bielefeld.de');
  $my_ua->timeout(60);
  $my_ua->max_size(5000000); # max 5MB

  # now the essentials

 # $query_str =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;

  my  $my_request = HTTP::Request->new('GET', $query_str) ;
  my  $my_response = $my_ua->request($my_request);

  return $my_response->content ;
}
  
=head2  extract_mods

 function to analyze sru mods responses
 and build up a hash with that

 Arguments:  $mods_xml - the mods xml file
             $limit    - maximum number of records

=cut

sub extract_mods {

   my ($mods_xml, $limit) = @_ ;

   my $xmlParser = new XML::Simple();

#   $mods_xml = push_xml ($mods_xml) ;

   # print_debug ($mods_xml, 'Mods-XML:') ;


   #  $mods_xml =~ tr /\t\n//d ;

   utf8::upgrade ($mods_xml) ;

   my $xml = $xmlParser->XMLin($mods_xml, forcearray => [ 'record', 'subject', 'relatedItem', 'detail', 'note', 'abstract', 
                                                          'name', 'role', 'titleInfo','extent', 'identifier']); # to make clear arrays for parsing

   my $num_recs = $xml->{numberOfRecords} ;

   # print_debug ($xml, 'Simple-XML:') ;

   my %response_hash ;

   $response_hash{numrecs} = $num_recs ;

#   shift (@{$xml->{records}->{record}}) ; # removing the first dummy record

   my $i = 0 ;

   if (!($limit)){ $limit = 0; } ;

   foreach my $entry (@{$xml->{records}->{record}}){

          my $hash_ref = add_record_fields (\$entry->{recordData}) ;
          push  (@{$response_hash{records}}, $hash_ref) ;
          if ($limit > 0){
             
              if ($i >= $limit){
                 last ;
              }
          } 
          $i++ ;
   }
   return \%response_hash ;
} 

=head2  add_record_fields

  function to analyze sru mods responses
  and build up a hash with that

=cut

  sub add_record_fields {

     my ($record_ref) = @_ ;
     my %hash_ref ;

     $hash_ref{recordid} = $$record_ref->{mods}->{recordInfo}->{recordIdentifier} ;
 
     if (ref ($$record_ref->{mods}->{genre})){ 
        $hash_ref{type} = $$record_ref->{mods}->{genre}->{content} ;
     }
     else { $hash_ref{type} = $$record_ref->{mods}->{genre} ; }

     foreach my $title_entry (@{$$record_ref->{mods}{titleInfo}}){

        push (@{$hash_ref{title}}, $title_entry->{title}) ;
     }

     #  $hash_ref{title} =  Encode::encode_utf8 ($$record_ref->{mods}->{titleInfo}->{title}) ;
     $hash_ref{publ_year} = $$record_ref->{mods}->{originInfo}->{dateIssued}->{content};
     $hash_ref{publisher} = $$record_ref->{mods}->{originInfo}->{publisher} ;

     $hash_ref{language} = $$record_ref->{mods}->{language}->{languageTerm}->{content};

     if ($$record_ref->{mods}->{originInfo}->{place}->{placeTerm}->{content})
     {
         $hash_ref{place} = $$record_ref->{mods}->{originInfo}->{place}->{placeTerm}->{content};
     }

     foreach my $note_entry (@{$$record_ref->{mods}{note}}){

          if ($note_entry->{type} eq 'publicationStatus'){
            
               $hash_ref{publstatus} = $note_entry->{content} ;
          }
          elsif ($note_entry->{type} eq 'reviewedWorks'){


             if ($note_entry->{content}){
                 
             
               my $temp = $note_entry->{content} ;

               $temp =~ s/au://; 
               $temp =~ s/ti// ; 
               $temp =~ tr/\n//d ;                  
               $hash_ref{reviewedwork} = $temp ;
             }
          }
     }

     foreach my $abstr_entry (@{$$record_ref->{mods}{abstract}}){

        if ($abstr_entry->{content}){
          push (@{$hash_ref{abstract}}, $abstr_entry->{content}) ;
        }  
     }

     my $author_ref ; 
#     $author_ref->{full} = '' ;
     my $affiliation_ref ;

     foreach my $auth_entry (@{$$record_ref->{mods}{name}}){
          
          if ($$auth_entry{role}[0]{roleTerm}{content}){

             my $auth_role = $$auth_entry{role}[0]{roleTerm}{content} ;
             
              if ($auth_role eq 'reviewer'){
                   
                  $auth_role = 'author' ;
              }

             if (ref ($auth_entry->{namePart}) eq 'ARRAY'){
                 
                  $author_ref->{full} = '' ;  
                  foreach my $author_part (@{$auth_entry->{namePart}}) {

                 #    $author_ref->{full} = '' ;  
                     if ($author_part->{type} eq 'given') {
                  
                         $author_ref->{full} = $author_ref->{full} . ', ' . $author_part->{content} ;
                         $author_ref->{given} = $author_part->{content} ;
                     }
                     elsif ($author_part->{type} eq 'family') {
                  
                         $author_ref->{full} = $author_part->{content}  . $author_ref->{full} ;
                         $author_ref->{family} = $author_part->{content} ;
                     }
                   }
            }
            elsif ($auth_role  eq 'department'){

                push (@{$hash_ref{affiliation}} , $auth_entry->{namePart}) ;
            }
            elsif ($auth_role  eq 'project'){

                push (@{$hash_ref{project}} , $auth_entry->{namePart}) ;
            }
            elsif ($auth_role  eq 'research group'){

                push (@{$hash_ref{researchgroup}} , $auth_entry->{namePart}) ;
            }

            if ($author_ref) {   # something found so push it

                $author_ref->{full} = trim ($author_ref->{full}) ;

                push (@{$hash_ref{$auth_role}}, $author_ref) ;
                $author_ref = undef ; # {}  ;
             #   $author_ref->{full} = '' ;
           }
         }
     }

      foreach my $subj_entry (@{$$record_ref->{mods}{subject}}){

          if (ref ($subj_entry->{topic}) eq 'ARRAY'){

              foreach my $subj_part (@{$subj_entry->{topic}}) {
                 push (@{$hash_ref{subject}}, $subj_part) ;
              }
          }
    #        else { 
    #         if ($subj_entry->{topic}){
    #             push (@{$hash_ref{subject}}, $subj_entry->{topic}) } ;
     #        }
      }

      my $entry ;
      foreach my $rel_entry (@{$$record_ref->{mods}{relatedItem}}){    # Citation information via related object

           my $rel_type = $rel_entry->{type} ;

           foreach my $title_entry (@{$rel_entry->{titleInfo}}){ 

                if ($title_entry->{title}){
                   $entry->{title} =  $title_entry->{title} ;
                }
           }

           if (ref ($rel_entry->{location}{url}))
           {
                if ($rel_entry->{type} eq 'constituent'){
                   push (@{$entry->{label}}, $rel_entry->{location}{url}{displayLabel}) ;
                }
                if ($rel_entry->{location}{url}{content}){
                   push (@{$entry->{url}}, $rel_entry->{location}{url}{content}) ; 
                }
           }
           elsif ($rel_entry->{location}{url}){

                if ($rel_entry->{type} eq 'constituent'){
                    $entry->{label} = $rel_entry->{location}{url} ;
                }
                else { $entry->{url} = $rel_entry->{location}{url} ; } 
           }

           foreach my $identifier_entry (@{$rel_entry->{identifier}}){

              if ($identifier_entry->{type} ne 'other'){

                 push (@{$entry->{$identifier_entry->{type}}}, $identifier_entry->{content}) ;
              }
              else {
           
                  if ($identifier_entry->{content} =~ /MEDLINE:(.*)/){
                      push (@{$entry->{medline}},  $1)   ;
                  }
                  if ($identifier_entry->{content} =~ /arXiv:(.*)/){
                      push (@{$entry->{arxiv}},  $1)   ;
                  }
                  if ($identifier_entry->{content} =~ /INSPIRE:(.*)/){
                      push (@{$entry->{inspire}},  $1)   ;
                  }
                  elsif ($identifier_entry->{content} =~ /BiPrints:(.*)/){
                        push (@{$entry->{biprints}},  $1)   ;
                  }
              }
             }      # some more           }

           foreach my $page_entry (@{$rel_entry->{part}{extent}}){
                    
                if ($page_entry->{content}){
                       $entry->{pages} = $page_entry->{content} ;
                }

                if ($page_entry->{start}){
      
                   $entry->{prange} .= $page_entry->{start}
                }
                if (!(ref $page_entry->{end})){
                    $entry->{prange} .=  ' - ' . $page_entry->{end} ;
                }
           }

           if ($rel_entry->{part}{detail}){

                foreach my $part_entry (@{$rel_entry->{part}{detail}}){

                if ($part_entry->{number}){
                     if ($part_entry->{type} eq 'volume'){
                        $entry->{volume} =    $part_entry->{number} ;            
                      }
                      if ($part_entry->{type} eq 'issue'){
                        $entry->{issue} =    $part_entry->{number} ;            
                      }
                   #  $entry->{($part_entry->{issue)} = $part_entry->{number} ;
               }
            }
          }

       # if ($$record_ref->{mods}->{relatedItem}->{part}->{detail}[0]->{number}){
       #            $hash_ref{relation}{volume} = $$record_ref->{mods}->{relatedItem}->{part}->{detail}[0]->{number} ;
        #     }
        # if ($$record_ref->{mods}->{relatedItem}->{part}->{detail}[1]->{number}){
        #           $hash_ref{relation}{issue} = $$record_ref->{mods}->{relatedItem}->{part}->{detail}[1]->{number} ;
        #     }
        if ($rel_entry){ 
             
            push  (@{$hash_ref{$rel_type}} , $entry) ; 
            $entry = {} ;
        }
    }

    return \%hash_ref ;        
}


=head2 switch_record_utf8


 function to switch the utf8 relevant fields of a cite record into utf8
=cut

sub switch_record_utf8 {

   my ($record_ref) = @_ ;

   foreach my $record (@{$record_ref->{records}}) {

    #   utf8::upgrade ($record->{title}) ;  

        foreach my $title (@{$record->{title}}){
           #  utf8::upgrade ($record->{$title}) ;
           $title = Encode::encode_utf8 ($title) ;
        } 
        
        if ($record->{place}){
           # utf8::upgrade ($record->{place}) ;
          $record->{place} = Encode::encode_utf8 ($record->{place}) ;
        }
        if ($record->{publisher}){
       #   utf8::upgrade ($record->{publisher}) ;
           $record->{publisher} = Encode::encode_utf8 ($record->{publisher}) ;
        }
       foreach my $abstract (@{$record->{abstract}}){
       #   utf8::upgrade($record->{abstract}) ;
           $abstract = Encode::encode_utf8 ($abstract) ;
        }
        if ( $record->{publ_year}){
           $record->{publ_year} = Encode::encode_utf8 ($record->{publ_year}) ;
        }
       foreach my $author (@{$record->{author}}){
      
           $author->{full} = Encode::encode_utf8 ($author->{full}) ;
           $author->{given} = Encode::encode_utf8 ($author->{given}) ;
           $author->{family} = Encode::encode_utf8 ($author->{family}) ;
       }
      foreach my $editor (@{$record->{editor}}){
      
           $editor->{full} = Encode::encode_utf8 ($editor->{full}) ;
           $editor->{given} = Encode::encode_utf8 ($editor->{given}) ;
           $editor->{family} = Encode::encode_utf8 ($editor->{family}) ;
       }
       foreach my $unit (@{$record->{relation}}){

          if ($unit->{'title'}){
   #          $unit->{'title'} =
            #    utf8::upgrade ($unit->{title}) ;
             $unit->{'title'} = Encode::encode_utf8 ($unit->{'title'}) ;
          }
       }
      last ; # only the first workaround for XML-Simple problem
   }
}

sub proc_coins {

     my ($record_ref) = @_ ;

     my $coins_str = '<span class="Z3988" title="ctx_ver=Z39.88-2004&amp;rft_val_fmt=info%3Aofi%2Ffmt%3Akev%3Amtx' ;

     if ($record_ref->{type} eq 'book' || $record_ref->{type} eq 'book chapter' ){
         $coins_str .= '%3Abook&amp;rft.genre=book' ;
       
         if ($record_ref->{title}){
           $coins_str .=  '&amp;rft.btitle=' . uri_escape ($record_ref->{title}) ;
         }
     }
     elsif ($record_ref->{type} eq 'article'){
         $coins_str .= '%3Ajournal&amp;rft.genre=article' ;
         if ($record_ref->{title}[0]){
           $coins_str .=  '&amp;rft.atitle=' . uri_escape_utf8 ($record_ref->{title}[0]) ;
         }
     }
     else  {return '' ;}

     if ($record_ref->{publ_year}){
           $coins_str .=  '&amp;rft.date=' . uri_escape ($record_ref->{publ_year}) ;
     }
     if ($record_ref->{place}){
           $coins_str .=  '&amp;rft.place=' . uri_escape ($record_ref->{place}) ;
     }
     if ($record_ref->{publisher}){
           $coins_str .=  '&amp;rft.pub=' . uri_escape ($record_ref->{publisher}) ;
     }

     my $i = 1 ;
     foreach my $author (@{$record_ref->{author}}){
      
         $coins_str .= '&amp;rft.au=' . uri_escape ($author->{full}) ;
         if  ($i++ > 3){ last } ;   
     }

     foreach my $unit (@{$record_ref->{relation}}){

     #    if ($unit->{url}){
     #         $record_hash{$i}{URL} = $unit->{url} ;
                 #   next ;
     #    }

         if ($unit->{pages}) {
           $coins_str .=  '&amp;rft.pages=' . uri_escape ($unit->{pages}) ;
         }
         if ($unit->{issue}){
             
             $coins_str .=  '&amp;rft.issue=' . uri_escape ($unit->{issue}) ;
         }
          if ($unit->{title}){
             $coins_str .=  '&amp;rft.jtitle=' . uri_escape_utf8 ($unit->{title}) ;
         }
         if ($unit->{volume}){
              $coins_str .=  '&amp;rft.volume=' . uri_escape ($unit->{volume}) ;
         }
      
         last ; # only the first entry
      }

     $coins_str .= '"></span>' ;

     return $coins_str ;
}

=head2 switch_author

 function to switch the parts of a author field around the comma

=cut

sub switch_author {

  my ($author) = @_ ;

  if ($author =~ /(.*?)\,(.*)/){

      $author = $2 . ' ' . $1 ;
  }
  return $author ;
}

=head2 push_xml

 function to create a workaround for xml parser problem

 it feeds a first dummy  record into the xml structure

=cut

sub push_xml {

 my ($string_ref) = @_ ;

 my  $addin_str = <<'INTEXT' ;
<records><record><genre>article</genre>
<titleInfo>
  <title>Genome sequence of Desulfobacterium autotrophicum HRM2, a marine sulfate reducer oxidizing organic carbon completely to carbon dioxide</title>
</titleInfo>
<name type="personal">
  <namePart type="given">Muriel</namePart>
  <namePart type="family">Foulonneau</namePart>
  <role> <roleTerm type="text">author</roleTerm> </role>
</name>
<name type="personal">
  <namePart type="given">Anne-Marie</namePart>
  <namePart type="family">Badolato</namePart>
  <role> <roleTerm type="text">author</roleTerm> </role>
</name>
<name type="personal">
  <namePart type="given">Wolfram</namePart>
  <namePart type="family">Horstmann</namePart>
  <role> <roleTerm type="text">author</roleTerm> </role>
  <affiliation>horstmann</affiliation>
</name>
<name type="personal">
  <namePart type="given">Karen</namePart>
  <namePart type="family">Van Godtsenhoven</namePart>
  <role> <roleTerm type="text">author</roleTerm> </role>
</name>
<name type="personal">
  <namePart type="given">Muellera</namePart>
  <namePart type="family">Jones</namePart>
  <role> <roleTerm type="text">author</roleTerm> </role>
</name>
<name type="personal">
  <namePart type="given">Sophia</namePart>
  <namePart type="family">Meier</namePart>
  <role> <roleTerm type="text">author</roleTerm> </role>
</name>
<name type="personal">
  <namePart type="given">Schmidt</namePart>
  <namePart type="family">Dummy</namePart>
  <role> <roleTerm type="text">author</roleTerm> </role>
</name>
<abstract lang="fre">Les archives institutionnelles en Europe se sont développées avec des logiques très différentes. Elles se sont
 structurées dans des réseaux nationaux pour partager les compétences mais aussi créer des outils et services communs.
 Le projet européen DRIVER (Digital Repositories Infrastructure Vision for European Research) rassemble 5 réseaux européens d’archives, en Allemagne, aux Pays-Bas,
 au Royaume-Uni, en Belgique et en France pour établir les bases d’une infrastructure européenne fondée sur les archives scientifiques
 L’Allemagne a mis l’accent sur la promotion du libre accès et la certification d’archives institutionnelles, les Pays-Bas ont structuré un réseau efficace de collecte
 des documents et ont créé de nombreux services à valeur ajoutée, pour tirer parti de cette masse de contenus. Le Royaume-Uni a créé un partenariat d’archives
 qui échange des compétences mais développe aussi de nombreux services dont bénéficient les archives britanniques ainsi que les archives mondiales.
des services à valeurs ajoutée basés sur des types d’archives différents, répondant à des besoins variés mais créant des corpus .</abstract>
</record>
INTEXT
 
   my @parts = split (/<records>/, $string_ref) ;

   if (scalar (@parts) > 1){

      $string_ref = $parts[0] . $addin_str .  $parts[1] ;
   }

   return $string_ref ;
}

=head2 prepare_sru_query

   method to fetch the relevant CGI query 
   params and transfer them into a SRU compliant hash

   Arguments: $query_ref = pointer on query hash_ref

   Return:    $url_str = string with LUP query

=cut

sub prepare_sru_query {

   my ($query_ref) = @_ ;

   my $url_str = '' ;

    if (defined ($q->param('ftext'))){  

      if ( $q->param('ftext') ne ''){
         $query_ref->{freetext} = $q->param('ftext') ; 
         $query_ref->{freetext} = proc_sru_query ($query_ref->{freetext}) ;
      }
      $url_str = "&ftext=" . $q->param('ftext') ; 
    }
    if ($q->param('author')){

       $query_ref->{author} = proc_sru_query ($q->param('author'), 'person') ; # '"' .  $q->param('author') . '"'  ;
       $url_str .= '&author=' . $q->param('author') ;
    }
    if ($q->param('editor')){

       $query_ref->{editor} =  '"' . $q->param('editor') . '"'   ;
       $url_str .= "&editor=" . $q->param('editor') ;
    }
    if ($q->param('project')){

       $query_ref->{project} =  '"' . $q->param('project') . '"'   ;
       $url_str .= "&project=" . $q->param('project') ;
    }
    if ($q->param('title')){

      $query_ref->{title} = $q->param('title') ;
      $query_ref->{title} = proc_sru_query ($query_ref->{title}) ;
      $url_str .= "&title=" . $q->param('title') ;
   }
   if ($q->param('lang') || $q->param('language') ){

      if ($q->param('lang')){
         $query_ref->{language} = $q->param('lang') ;
      }
      else {
           $query_ref->{language} = $q->param('language') ;
      }
      $query_ref->{language} = proc_sru_query ( $query_ref->{language}) ;
      $url_str .= "&language=" . $query_ref->{language} ;
   }
   if ($q->param('publyear') || $q->param('publishingYear') ){

      if ($q->param('publyear')){
         $query_ref->{publishingYear} = $q->param('publyear') ;
      }
      else {
           $query_ref->{publishingYear} = $q->param('publishingYear') ;
      }
      $query_ref->{publishingYear} = proc_sru_query ($query_ref->{publishingYear}) ;
      $url_str .= "&publishingYear=" . $query_ref->{publishingYear} ;
   }
   if ($q->param('doctype')  || $q->param('documentType') ){

      if ($q->param('doctype')){
           $query_ref->{documentType} =  proc_sru_query ($q->param('doctype')) ;
      }
      else {
           $query_ref->{documentType} = proc_sru_query ($q->param('documentType')) ;
      }
      $url_str .= "&documentType=" . $query_ref->{documentType} ;
   }
   if ($q->param('dept') || $q->param('department') ){

      if ($q->param('dept')){ 
          $query_ref->{department} = $q->param('dept') ;
      }
      else {
            $query_ref->{department} = $q->param('department') ;
      }
      $url_str .= "&department=" . $query_ref->{department} ;
   }
   if (defined ($q->param('extern')) || defined ($q->param('nonLu'))){

      if ($q->param('extern') =~ /^0|1/){
         $query_ref->{'nonLu'} = proc_sru_query ($q->param('extern'), 'flag') ;
      }
      elsif ($q->param('nonLu') =~ /^0|1/){
         $query_ref->{'nonLu'} = proc_sru_query ($q->param('nonLu'), 'flag') ;
      }
      $url_str .= '&extern=' . $q->param('extern')  ; 
   }
   
   if (defined ($q->param('fulltext'))){

      if ($q->param('fulltext') =~ /^0|1/){
  
         $query_ref->{'fulltext'} = proc_sru_query ($q->param('fulltext'), 'flag') ;
      }
      $url_str .= '&fulltext=' . $q->param('fulltext')  ; 
   } 

   return $url_str ;
}

=head2 proc_sru_query

   method to transfer a search form query to  SRU compliant format

=cut

sub proc_sru_query {

   my ($form_string, $typus) = @_ ;

   $form_string =~ tr / / /s ;  # reduces blanks to one

 #  $form_string =~ s/\>/%3E/ ;

   if ($form_string =~ /^\"/){   # phrase processing

           return $form_string ;
   }
  
   if (!($typus)){

      if ($form_string =~ /^!(.*)/) {  # negation only for the whole term
        
           $form_string = "NOT $1" ;
           return $form_string ;
      }

      my @query_list = split (/ /, $form_string ) ;

      my $query_str = $query_list[0] ;


      for (my $i = 1 ; $i <= $#query_list; $i++){

        if ($query_list[$i] !~ /AND|OR/i){

           $query_str .= '%20AND%20' . $query_list[$i] ; 
        }
        else { 

           $query_str .= '%20' . $query_list[$i] . '%20' . $query_list[++$i] ; 
        }   
      }

      return $query_str ;
  }
  elsif ($typus eq 'person'){  # processing person phrases
 
        return '%20all%20%22' . $form_string . '%22' ;     
   }
   elsif ($typus eq 'flag'){

       if ($form_string eq '1'){
       
            return '%20exact%20%221%22' ;
       }
       elsif ($form_string eq '0') { return 'NOT%20exact%221%22' ; }

       # else return '%
   }
}

=head2 user_adress

 tool function to extract
 the user ip adress

=cut

sub user_adress {

   my $ipaddr = $ENV{'REMOTE_ADDR'};
   my $addr = $ENV{'REMOTE_HOST'};
   unless ($addr) {$addr = $ipaddr}
      my $forward = $ENV{'HTTP_FORWARDED'};
      my $xforward = $ENV{'HTTP_X_FORWARDED_FOR'};
   if ($xforward) {
      if ($xforward =~ /\d+\.\d+\.\d+\.\d+/) {
      $ipaddr = $xforward;
      $addr = $xforward;
    }
   }
   if ($forward) {
    my ($schrott,$raddr) = split(/for/,$forward);
    $raddr =~ s/\s*//;
    if ($raddr =~ /\d+\.\d+\.\d+\.\d+/) {
      $ipaddr = $raddr;
      $addr = $raddr;
    }
   }
   $addr = substr ($addr,0,98);
   unless ($ipaddr =~ /\d+\.\d+\.\d+\.\d+/) {$ipaddr = ""}
   $addr =~ s/[^A-Za-z0-9\.\-\_]//g;

   return $addr;
}


=head2 trim

 tool function to remove whitespaces
 at begin and end of string

=cut

sub trim {

   my ($str)  = @_;

   if ($str)
   {
      $str  =~ s/^\s+|\s+$//g;
   }
   return $str;
}

=head2 print_debug

  tool function to print debug information

=cut

sub print_debug {

   if ($cfg->{pub}->{debug})  # ;$debug)
   {
      my ($text, $intro) = @_ ; 

      my ($sec,$min,$hour, $DayOfMonth, $RealMonth, $Year)  = (localtime(time()))[0..5] ;
      $Year += 1900 ;
      $RealMonth++ ;
      
      use Data::Dumper;
       if (open (FILE, ">>/tmp/bup_debug.txt") ) {
              print FILE "\n$Year-$RealMonth-$DayOfMonth,$hour-$min-$sec   " ;
              if ($intro){
                  print FILE $intro ;
              } 
              if ($text){
                  print FILE Dumper ($text);
              }
              else {
                  print FILE "   ---Var undefined" ;
              }
              close (FILE);
     }
   }
}
