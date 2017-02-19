/*
 * @progname       sag.ll
 * @version        0.1
 * @author         Dirk Laurie
 * @category       
 * @output         HTML wrapping plain text, for now
 * @description

@(#)sag.ll	0.1 9/2/2017
*/

global(MAXLINES)
global(linecount)
global(gens)
global(teiken)   /* "html" or "pandoc" */
global(vooraf)   /* something needed at the start of every line; target-dependent */

proc main () {

/* Preferences */             
  set(teiken,"html")          /* Default target is html */
  if (t,getproperty("format")) { set(teiken,t) }
  set(I1,"I1")                /* Default progenitor is I1 */
  if (t,getproperty("start")) { set(I1,t) }
  set(voorvader,indi(I1))   
  set(gens, 100)                /*Default depth is practically infinite */
  if (t,getproperty("depth")) { set(gens,strtoint(t)) }
/* SAG Afrikaanse datumformate */
  complexpic(0,"c.%1")
  complexpic(3,"<%1")
  complexpic(4,">%1")
/* ----------- */

  set(MAXLINES,500)           /* set max report lines */
  set(linecount,0)            /* initialize linecount */
  dayformat(1)       /* leading zero before single digit days */
  monthformat(1)     /* leading zero before single digit months */
  set(charset,"utf-8")   /* Assume ancient GEDCOM */

  if (eq(teiken,"pandoc")) { set(vooraf,"| ") }  /* PanDoc markdown: line block */

  if (eq(teiken,"html")) {
"<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">
<html xmlns=\"http://www.w3.org/1999/xhtml\">
<head>
  <meta http-equiv=\"Content-Type\" content=\"text/html; charset="
charset
"\" />
</head>
<body>"
  "<PRE>\n" }

  call gen2sa(voorvader,1,1)

  if (eq(teiken,"html")) {
  "</PRE>\n"

"</body>
</html>" }
}

/* persoon     IND     first parent in this family
   geslag      INT     generation number
   nommer      INT     number of person within family
*/
proc gen2sa(persoon,geslag,nommer) {
  if (gt(geslag,gens)) { return() }
  set(inkeep,mul(geslag,4))
  set(kode,deVPama(geslag,nommer))
  set(huwelik,"")
  set(kindno,0)
  set(vorige,0)
    /* vertoon voorouer */
  vooraf rjustify(" ",sub(geslag,1)) rjustify(kode,sub(inkeep,geslag)) " " 
  call beskryf(persoon) "\n"
    /* ---------------- */
  families (persoon, gesin, eggenoot, gesinnommer) {
    set(huwelik,concat(huwelik,"x"))
    if (gt(vorige,0))            /* was daar kinders uit die vorige huwelik? */
      { set(hkode,concat(kode,huwelik)) } /* herhaal dan eerste ouer se kode */
    else { set(hkode,huwelik) }  /* anders nie */
    vooraf rjustify(hkode,add(inkeep,1)) " " 
    if(troue, marriage(gesin)) {
      sagplace(troue) sagdate(troue)
    }    
    call beskryf(eggenoot) "\n" 
    set(vorige,nchildren(gesin))
    children (gesin, kind, j) {
      incr(kindno)
      call gen2sa(kind,add(geslag,1),kindno)
    }
  } 
}

func deVPama(geslag,nommer) {
  return(concat(alpha(geslag),d(nommer)))
}

func christening(indi) {
    fornodes(indi,node) {
        if (index(" CHR ",upper(tag(node)),1)) {
            return(node)
        }
    }
    return(0)
}

proc beskryf(persoon) {
  if(not(persoon)) { return() }
  fullname(persoon,1,1,80)
  if(geboorte, birth(persoon)) {
    " * " sagplace(geboorte) sagdate(geboorte)
  }
  if(gedoop, christening(persoon)) {
    "≈ " sagplace(gedoop) sagdate(gedoop)
  }
  if(dood, death(persoon)) {
    "† " sagplace(dood) sagdate(dood)
  }
  if(begrawe, burial(persoon)) {
    "Ω " sagplace(begrawe) sagdate(begrawe)
  }
}


/* Different datepics depending on whether day and/or month is missing */
func sagdate(gebeur) {
  datepic("%d.%m.%y ")   /* Probeer eers volledige datum */
  set(s,stddate(gebeur))
  if (le(index(s," ",1),2)) { /* volledige datum nie beskikbaar nie */
    datepic("%m.%y ")         /* Dalk maand en jaar? */
    set(s,stddate(gebeur)) 
    if (le(index(s," ",1),2)) { /* ook nie, dan jaar alleen */
      datepic("%y ")
    }
  }
  return (complexdate(gebeur))
}

func sagplace(gebeur) {
  if (plek,place(gebeur)) {
    if (j,index(plek,",",1)) {  /* Gooi alles na eerste komma weg */
      set(plek,substring(plek,1,sub(j,1)))
    }
    return(concat(plek," "))
  }
}


/******************************************************************************/

/*
   key_no_char:
     Return string key of individual or family, without
     leading 'I' or 'F'.
*/
proc key_no_char (nm) {
    set(k, key(nm))
    substring(k,2,strlen(k))
} 
