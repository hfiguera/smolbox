import {build} from 'esbuild';
await build({entryPoints:['js/app.js'], bundle:true, minify:true, outdir:'../priv/static/assets', loader:{'.woff2':'file','.woff':'file'}, target:['es2022']});
