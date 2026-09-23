const THEME_BOOTSTRAP = `(()=>{try{const saved=localStorage.getItem('voiid-theme');const theme=saved==='dark'?'dark':'light';document.documentElement.dataset.theme=theme;document.documentElement.style.colorScheme=theme;const meta=document.querySelector('meta[name="theme-color"]');if(meta)meta.setAttribute('content',theme==='dark'?'#07110f':'#fbfcfc')}catch{document.documentElement.dataset.theme='light'}})()`;

export function ThemeScript() {
  return <script dangerouslySetInnerHTML={{ __html: THEME_BOOTSTRAP }} />;
}
