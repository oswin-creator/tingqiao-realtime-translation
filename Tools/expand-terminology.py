#!/usr/bin/env python3
"""Offline extension from downloaded official concept mappings and Wikidata.

No network unless --download is explicit. Existing runtime/user files are never
written. Source labels are Wikidata CC0, never machine translated. The STW
mapping used for candidate discovery is separately published under CC0.
"""
import argparse,collections,gzip,hashlib,importlib.util,json,re,time,urllib.request,urllib.parse,urllib.error,zipfile
from pathlib import Path
from datetime import datetime,timezone
PROJECT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('wd_builder',PROJECT/'Tools/update-wikidata.py');wd=importlib.util.module_from_spec(spec);spec.loader.exec_module(wd)
UA='TingQiaoTerminology/0.2.23 (https://github.com/oswin-creator/tingqiao-realtime-translation; offline vocabulary preparation)'
LANGS=['en','ko','zh','ja','de','fr','es']
class Queries:
 def __init__(self,root):self.root=root;self.next=0;self.calls=0
 def run(self,q):
  key=hashlib.sha256(q.encode()).hexdigest();f=self.root/('query-'+key+'.json.gz')
  if f.exists():return json.loads(gzip.decompress(f.read_bytes()))['results']['bindings']
  for attempt in range(2):
   wait=self.next-time.monotonic()
   if wait>0:time.sleep(wait)
   t=time.monotonic();self.next=t+6.5
   try:
    req=urllib.request.Request('https://query.wikidata.org/sparql?'+urllib.parse.urlencode({'query':q,'format':'json'}),headers={'User-Agent':UA,'Accept':'application/sparql-results+json','Accept-Encoding':'gzip'})
    with urllib.request.urlopen(req,timeout=45) as r:
     data=r.read(24*1024*1024+1)
     if len(data)>24*1024*1024:raise ValueError('oversize response')
     if r.headers.get('Content-Encoding')=='gzip':data=gzip.decompress(data)
    result=json.loads(data);assert 'results' in result
    wd.atomic_write(f,gzip.compress(data,mtime=0));self.calls+=1
    print('REQUEST',self.calls,'rows',len(result['results']['bindings']),'seconds',round(time.monotonic()-t,1),flush=True)
    return result['results']['bindings']
   except (OSError,ValueError,TimeoutError) as e:
    wait=15
    if isinstance(e,urllib.error.HTTPError):
     if e.code not in (429,500,502,503,504):raise
     try:wait=max(15,int(e.headers.get('Retry-After','15')))
     except ValueError:pass
    print('RETRY',type(e).__name__,'wait',wait,'attempt',attempt+1,flush=True);self.next=time.monotonic()+wait
  raise RuntimeError('query failed twice; cached files retained')
 def entities(self,ids):
  values=' '.join('wd:'+q for q in ids)
  labels=' '.join('OPTIONAL{?item rdfs:label ?l'+str(i)+'.FILTER(LANG(?l'+str(i)+')="'+lang+'")} ' for i,lang in enumerate(LANGS))
  q='SELECT ?item ?description '+' '.join('?l'+str(i) for i in range(len(LANGS)))+' WHERE {VALUES ?item { '+values+' } ?item schema:description ?description.FILTER(LANG(?description)="en") '+labels+' }'
  out={}
  for row in self.run(q):
   qid=row['item']['value'].rsplit('/',1)[-1]
   out[qid]={'id':qid,'labels':{lang:{'value':row['l'+str(i)]['value']} for i,lang in enumerate(LANGS) if 'l'+str(i) in row},'descriptions':{'en':{'value':row['description']['value']}},'sitelinks':{}}
  return out
 def wiki_counts(self,ids):
  values=' '.join('wd:'+q for q in ids)
  q='SELECT ?item (COUNT(DISTINCT ?article) AS ?count) WHERE {VALUES ?item {'+values+'} ?article schema:about ?item. FILTER(CONTAINS(STR(?article),".wikipedia.org/wiki/")) } GROUP BY ?item'
  return {x['item']['value'].rsplit('/',1)[-1]:int(x['count']['value']) for x in self.run(q)}

def load_candidates(cache):
 scopes={}
 for kind,domain in [('statistics','statistics'),('computer-science','computer-science'),('mathematics','mathematics')]:
  f=cache/(kind+'-small.json')
  if not f.exists():continue
  for row in json.loads(f.read_bytes())['results']['bindings']:
   qid=row['item']['value'].rsplit('/',1)[-1]
   if re.fullmatch(r'Q[1-9]\d*',qid):scopes.setdefault(qid,domain)
 return scopes

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--cache',type=Path,default=PROJECT/'.qa-data/terminology-expansion-20261106')
 parser.add_argument('--output',type=Path,default=PROJECT/'build/terminology/expanded-20261106/wikidata.json')
 parser.add_argument('--download',action='store_true')
 args=parser.parse_args();cache=args.cache;queries=Queries(cache)
 base=json.loads((PROJECT/'Resources/wikidata.json').read_text());original={e['id'] for e in base['entries']}
 old=json.loads(gzip.decompress((cache/'previous-entities.json.gz').read_bytes()))
 scopes=load_candidates(cache)
 with zipfile.ZipFile(cache/'stw_wikidata_mapping.nt.zip') as z:
  data=z.read(z.namelist()[0]).decode()
  matches=set(re.findall(r'<http://www.wikidata.org/entity/(Q\d+)> <http://www.w3.org/2004/02/skos/core#exactMatch> <http://zbw.eu/stw/descriptor/[^>]+>',data))
 for q in matches:scopes.setdefault(q,'business')
 # Only bibliographically well represented MeSH descriptors, not supplementary
 # chemicals; the existing medicine layer remains intact.
 discovery='SELECT DISTINCT ?item ?links WHERE {?item wdt:P486 ?code;wikibase:sitelinks ?links.FILTER(STRSTARTS(?code,"D") && ?links>=4)} ORDER BY DESC(?links) LIMIT 16000'
 if args.download:
  rows=queries.run(discovery);wd.atomic_write(cache/'mesh-descriptor-candidates.json',wd.encode(rows))
 f=cache/'mesh-descriptor-candidates.json'
 if f.exists():
  chosen=[x['item']['value'].rsplit('/',1)[-1] for x in json.loads(f.read_bytes()) if 'wd-'+x['item']['value'].rsplit('/',1)[-1] not in original]
  for q in chosen[:3000]:
   if scopes.get(q)=='mathematics':scopes[q]='medicine'
   else:scopes.setdefault(q,'medicine')
 # All old IDs are preserved byte-for-byte at the entry level.
 scopes={q:d for q,d in scopes.items() if 'wd-'+q not in original}
 newfile=cache/'new-entities.json.gz';fresh=json.loads(gzip.decompress(newfile.read_bytes())) if newfile.exists() else {}
 # Reuse the source-attested labels already obtained in the small domain
 # exports. Do not download those entities again merely for extra languages.
 for domain in ['statistics','computer-science','mathematics']:
  f=cache/(domain+'-small.json')
  if not f.exists():continue
  for row in json.loads(f.read_bytes())['results']['bindings']:
   q=row['item']['value'].rsplit('/',1)[-1]
   if q in old or q in fresh or q not in scopes:continue
   labels={lang:{'value':row[lang]['value']} for lang in ['en','ko','zh','ja'] if lang in row}
   fresh[q]={'id':q,'labels':labels,'descriptions':{'en':{'value':row['description']['value']}},'sitelinks':{}}
 wd.atomic_write(newfile,gzip.compress(wd.encode(fresh),mtime=0))
 needed=sorted(set(scopes)-set(old)-set(fresh),key=lambda q:(scopes[q]!='business',scopes[q]!='medicine',int(q[1:])))
 print('CANDIDATES',dict(collections.Counter(scopes.values())),'uncached entities',len(needed),flush=True)
 if args.download:
  for start in range(0,len(needed),150):
   batch=needed[start:start+150];print('ENTITY BATCH',start+1,'/',len(needed),flush=True)
   fresh.update(queries.entities(batch));wd.atomic_write(newfile,gzip.compress(wd.encode(fresh),mtime=0))
 entities={**old,**fresh};countsfile=cache/'wikipedia-counts.json';counts=json.loads(countsfile.read_text()) if countsfile.exists() else {}
 # Skip expensive site counting for rejected label/description candidates.
 preliminary=[]
 geo=re.compile(r'\b(country|city|village|municipality|prefecture|province|island|continent|town|county|capital city|geographical region)\b',re.I)
 people=re.compile(r'^(?:\w+[- ]+){0,4}(economist|politician|philosopher|mathematician|scientist|physicist|author|researcher)\b',re.I)
 rejected=collections.Counter()
 for q,domain in scopes.items():
  entity=entities.get(q)
  if not entity:rejected['unavailable_entity']+=1;continue
  desc=entity.get('descriptions',{}).get('en',{}).get('value','')
  if geo.search(desc) or people.search(desc):rejected['geography_or_person']+=1;continue
  # Taxonomy paths and thesaurus mappings alone are not sufficient evidence:
  # some broad/deep branches contain speech synthesis under statistics or even
  # religious narratives under computing. Require independent textual domain
  # evidence for each NEW concept; existing verified entries stay untouched.
  evidence={
   'statistics':r'statistic|probabilit|regression|hypothesis|distribution|sampling|stochastic|random|inference|estimat|multivariate|bayes|likelihood|correlation|anova|time series|data analysis|monte carlo|nonparametric|variance|survey|experimental design|markov|econometric',
   'computer-science':r'comput|algorithm|program|software|data structure|data compress|image compress|cryptograph|cipher|network|protocol|machine learning|artificial intelligence|database|web|internet|encryption|cyber|data mining|informat|digital|search engine|neural network|operating system|computer science',
   'business':r'financ|economic|economy|market|trade|monetar|bank|invest|currenc|stock|business|enterprise|management|production|consumption|demand|supply|cost|price|wealth|capital|resource|labor|labour|employment|worker|workforce|tax|income|insurance|accounting|asset|retail|industry|industrial|commercial|commerce|corporat|socioeconomic|welfare|policy|profit|credit|debt|loan|bond|valuation|budget|payment|fiscal|entrepreneur|sales|selling|goods|service|ownership|competition|utility|logistic|purchas|rental|real estate|contract|wage|salary|pension|firm|regulation|allocation|consumer|employer|manager|venture|patent|productivity|elasticity|econometric',
   'mathematics':r'mathemat|algebra|geometr|topolog|theorem|lemma|proof|number|integer|calculus|differential|equation|arithmet|trigonomet|function|vector|matrix|matrices|coordinate|combinator|graph theory|set theory|operator|polynomial|complex plane|ring|field theory|banach|hilbert|metric|normed|manifold|fractal|curvature|polygon|polyhed|quadrilateral|triangle|angle|circle|sphere|tensor|transform|integral|derivative|category theory|homology|homotopy|morphism|bundle|euclidean|riemann|divisor|modulo|modular|sequence|series|measure theory|poset|lattice|symmetry|permutation|symplectic|lie group|logarithm|exponential|binary|unitary|quantifier',
   'medicine':r'medic|health|clinic|disease|disorder|syndrome|symptom|diagnos|therap|treatment|surg|anatom|organ|tissue|cell|blood|vascular|neuro|brain|cardiac|respirat|kidney|renal|liver|hepatic|pulmon|infection|inflamm|immune|immuno|cancer|tumou?r|carcinoma|biolog|biomed|pharmac|drug|dose|toxic|patholog|epidemi|protein|enzyme|hormone|receptor|membrane|bone|muscle|nerve|skin|pain|abnormal|fracture|tooth|dental|bacteri|virus|viral|fungal|mycos|genetic|metabol|biochem|chromosome|gene expression|nucleic|genome|physiol|pregnan|childbirth|vaccine|vaccination|nursing|patient|hospital|mortality|morbidity|disability|rehabilit|psycholog|psychiatr|behavior|behaviour|cognition|mental|sensory|vision|hearing|spinal|retina|cornea|diabetes|epilep|digest|arter|vein|circulation|human body'}
  if re.search(r'\b(song|album|film|novel|short story|television series|fictional character|religious narrative|parable of Jesus)\b',desc,re.I):rejected['media_or_story']+=1;continue
  title=entity.get('labels',{}).get('en',{}).get('value','')
  if domain in evidence and re.search(evidence[domain],desc,re.I) is None:rejected['domain_evidence_missing']+=1;continue
  preferred=wd.normalized(title)
  general={'coffee','tea','milk','water','food','day','night','man','woman','child','people','person','thing','hello','thanks','thank you','book','table','chair','car','tree','animal','plant','fish','rice','fruit','vegetable','meat','bread','sugar','salt','air','sun','moon','earth','year','month','week'}
  if preferred in general:rejected['ordinary_vocabulary']+=1;continue
  if domain=='business' and re.search(r'\b(species of|genus of|chemical compound|chemical element|beverage|alcoholic drink|tree species)\b',desc,re.I):rejected['non_economic_physical_entity']+=1;continue
  # Probe lexical/schema gates without fabricating sitelink records. Actual
  # article counts below are mandatory before any entry is accepted.
  if wd.convert(entity,domain,wikipedia_count=2) is None:rejected['lexical_quality']+=1;continue
  preliminary.append(q)
 count_needed=[q for q in preliminary if q not in old and q not in counts]
 if args.download:
  for start in range(0,len(count_needed),400):
   batch=count_needed[start:start+400];print('WIKI COUNT BATCH',start+1,'/',len(count_needed),flush=True)
   found=queries.wiki_counts(batch);counts.update({q:found.get(q,0) for q in batch});wd.atomic_write(countsfile,wd.encode(counts))
 additions=[];provenance={};unverified=0
 for q in preliminary:
  entity=entities[q]
  n=sum(re.fullmatch(r'[a-z]{2,3}(?:_[a-z]{2,8})*wiki',k) is not None for k in entity.get('sitelinks',{})) if q in old else counts.get(q)
  if n is None:unverified+=1;continue
  converted=wd.convert(entity,scopes[q],wikipedia_count=n)
  if converted is None:rejected['encyclopedic_coverage']+=1;continue
  entry,sources=converted;additions.append(entry);provenance[entry['id']]={'source':'Wikidata','discovery':'STW exactMatch CC0' if q in matches else ('MeSH descriptor mapping' if scopes[q]=='medicine' else 'typed concept descendants'),'languageSources':sources,'wikipediaArticles':n,'revision':entity.get('lastrevid')}
 signatures={(e['domain'],tuple((lang,wd.normalized(form['preferred'])) for lang,form in sorted(e['forms'].items()))) for e in base['entries']}
 unique=[]
 for entry in additions:
  signature=(entry['domain'],tuple((lang,wd.normalized(form['preferred'])) for lang,form in sorted(entry['forms'].items())))
  if signature in signatures:rejected['identical_multilingual_signature']+=1;provenance.pop(entry['id'],None);continue
  signatures.add(signature);unique.append(entry)
 additions=unique
 same_label=collections.Counter(wd.normalized(e['forms']['en']['preferred']) for e in base['entries']+additions)
 for entry in additions:
  if same_label[wd.normalized(entry['forms']['en']['preferred'])]>1:entry['kind']='contextual'
 additions.sort(key=lambda e:('ko' not in e['forms'],'zh-CN' not in e['forms'],e['domain'] not in ['statistics','computer-science','business'],int(e['id'].split('Q')[-1])))
 additions=additions[:50000-len(base['entries'])]
 merged={**base,'entries':base['entries']+additions};payload=wd.encode(merged)
 if len(payload)>32*1024*1024:raise ValueError('aggregate package exceeds 32 MiB')
 report={'source':'Wikidata','license':'CC0-1.0','schemaVersion':1,'entries':len(merged['entries']),'sha256':hashlib.sha256(payload).hexdigest(),'generatedAt':datetime.now(timezone.utc).isoformat(),'bytes':len(payload),'previousEntries':len(base['entries']),'added':len(additions),'unverifiedNotAdded':unverified,'rejected':dict(rejected),'domains':dict(collections.Counter(e['domain'] for e in merged['entries'])),'languages':dict(collections.Counter(lang for e in merged['entries'] for lang in e['forms'])),'newEntities':provenance,'selection':'Existing entries retained; source-attested labels only; >=3 independent languages, >=2 Wikipedia articles; exact STW mapping only; MeSH descriptors, not supplementary concepts; geography/person exclusions','mappingSource':'https://zbw.eu/stw/version/latest/mapping/wikidata/about.en.html','mappingLicense':'CC0-1.0','stwDataDownloadedButLabelsNotImported':True}
 if args.download and unverified:raise ValueError('incomplete verification; no output replaced')
 if len(additions)<100:raise ValueError('too few additions; no output replaced')
 wd.atomic_write(args.output,payload);wd.atomic_write(args.output.with_suffix('.manifest.json'),wd.encode(report))
 print('READY',len(merged['entries']),'ADDED',len(additions),'BYTES',len(payload),'LANGS',report['languages'],'UNVERIFIED',unverified,flush=True)
if __name__=='__main__':main()
