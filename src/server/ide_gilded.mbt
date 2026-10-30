///|
/// The IDE a moongql endpoint serves by default: a page built by the library
/// itself, in the same language as the rest of the documentation — a gold-haired
/// plate, the document on the left, the answer on the right, and a schema drawer.
///
/// It needs nothing from a CDN and nothing from a bundler: the whole page is one
/// string `Ide::html` returns. Because the endpoint serves the page, its path is
/// baked in at request time.
///
/// The interaction is the one the documentation's playground has: a field lit on
/// one side lights the same field on the other, dims everything else, and names
/// its path with the type the schema declares for it. That is not decoration —
/// with a document and a response side by side, "which line did this field come
/// from" is the question people actually ask.

///|
/// The page up to the endpoint literal. Everything after it is `gilded_tail`.
fn gilded_head() -> String {
  let head =
    #|<!DOCTYPE html>
    #|<html lang="en">
    #|<head>
    #|  <meta charset="utf-8" />
    #|  <meta name="viewport" content="width=device-width, initial-scale=1" />
    #|  <title>MoonQL</title>
    #|  <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect x='3.5' y='3.5' width='25' height='25' fill='none' stroke='%23c9a84c' stroke-width='1'/%3E%3Crect x='7.5' y='7.5' width='17' height='17' fill='none' stroke='%23c9a84c' stroke-width='.6' opacity='.6'/%3E%3Ccircle cx='16' cy='16' r='4' fill='%23e9e3d4'/%3E%3C/svg%3E" />
    #|  <link rel="preconnect" href="https://fonts.googleapis.com" />
    #|  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    #|  <link href="https://fonts.googleapis.com/css2?family=Cinzel:wght@400;500&family=Cormorant+Garamond:wght@400;500&family=Inter:wght@300;400;500&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet" />
    #|  <style>
    #|    :root{
    #|      --bg:#07060a; --panel:#100d17; --panel-2:#151120; --abyss-2:#0b0912;
    #|      --ink:#e9e3d4; --muted:#9b917c; --faint:#6d6555;
    #|      --gold:#c9a84c; --gold-hi:#eed89b; --hair:rgba(201,168,76,.22);
    #|      --gold-dim:rgba(201,168,76,.34); --azure:#4a90d9; --crimson:#e8837a;
    #|      --flash:rgba(238,216,155,.55); --flash-soft:rgba(238,216,155,.32);
    #|      --serif:"Cormorant Garamond",ui-serif,Georgia,serif;
    #|      --caps:"Cinzel",ui-serif,Georgia,serif;
    #|      --sans:"Inter",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
    #|      --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
    #|    }
    #|    *{box-sizing:border-box}
    #|    html,body{height:100%}
    #|    body{margin:0;color:var(--ink);font-family:var(--sans);
    #|      font-size:15px;line-height:1.65;-webkit-font-smoothing:antialiased;overflow:hidden;
    #|      background:
    #|        radial-gradient(120% 90% at 50% -12%,#141019 0%,var(--bg) 62%),
    #|        radial-gradient(90% 60% at 50% 116%,var(--abyss-2) 0%,transparent 68%)}
    #|    ::selection{background:rgba(201,168,76,.3);color:var(--ink)}
    #|    :where(a,button,input,textarea,[tabindex]):focus-visible{
    #|      outline:1px solid var(--gold);outline-offset:3px;border-radius:2px}
    #|    .play{height:100%;display:grid;grid-template-rows:3.4rem minmax(0,1fr)}
    #|    button{font:inherit;color:inherit}
    #|    .bar{display:flex;align-items:center;gap:.85rem;padding:0 1.15rem;
    #|      border-bottom:1px solid var(--hair);background:var(--panel)}
    #|    .mark{width:21px;height:21px;flex:none}
    #|    .name{font-family:var(--caps);font-size:.82rem;letter-spacing:.22em;
    #|      text-transform:uppercase;color:var(--ink)}
    #|    .sub{font-family:var(--sans);font-size:.6rem;letter-spacing:.14em;
    #|      text-transform:uppercase;color:var(--muted);border-left:1px solid var(--hair);
    #|      padding-left:.6rem;margin-left:.05rem;white-space:nowrap}
    #|    .url{font-family:var(--mono);font-size:.75rem;color:var(--gold);
    #|      border:1px solid var(--hair);border-radius:2px;padding:.1rem .45rem;
    #|      max-width:20rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    #|    /* the bar's empty middle carries one very faint rule, the way the plates
    #|       separate a document from its answer */
    #|    .acts{display:flex;align-items:center;gap:.85rem;flex:none}
    #|    .spacer{flex:1;position:relative;align-self:stretch;margin:0 .7rem}
    #|    .spacer::before{content:"";position:absolute;left:0;right:0;top:50%;height:1px;
    #|      background:repeating-linear-gradient(90deg,var(--hair) 0 3px,transparent 3px 10px);
    #|      opacity:.55}
    #|    .state{font-family:var(--mono);font-size:.72rem;color:var(--muted)}
    #|    .state.ok{color:var(--gold-hi)} .state.bad{color:var(--crimson)}
    #|    .btn{background:none;border:1px solid var(--hair);border-radius:2px;color:var(--muted);
    #|      font-size:.8rem;padding:calc(.34rem + .1em) .7rem calc(.34rem - .1em);cursor:pointer;
    #|      transition:color .15s,border-color .15s}
    #|    /* every button wears the same mount the documentation uses: a hairline
    #|       border, then a second line three pixels in */
    #|    .btn{position:relative}
    #|    .btn::after{content:"";position:absolute;inset:3px;border:1px solid rgba(201,168,76,.13);
    #|      border-radius:1px;transition:border-color .25s;pointer-events:none}
    #|    .btn:hover{color:var(--gold-hi);border-color:var(--gold-dim)}
    #|    .btn:hover::after{border-color:var(--gold-dim)}
    #|    .btn.run{color:var(--ink);border-color:var(--gold-dim);
    #|      background:linear-gradient(180deg,rgba(201,168,76,.18),transparent)}
    #|    .btn.run:hover{color:var(--gold-hi);border-color:var(--gold)}
    #|    /* Run is the one plate in the bar: corner brackets that overshoot it */
    #|    .btn.run::before{content:"";position:absolute;inset:-3px;pointer-events:none;opacity:.85;
    #|      background:
    #|        linear-gradient(var(--gold-dim),var(--gold-dim)) left top/9px 1px no-repeat,
    #|        linear-gradient(var(--gold-dim),var(--gold-dim)) left top/1px 9px no-repeat,
    #|        linear-gradient(var(--gold-dim),var(--gold-dim)) right top/9px 1px no-repeat,
    #|        linear-gradient(var(--gold-dim),var(--gold-dim)) right top/1px 9px no-repeat,
    #|        linear-gradient(var(--gold-dim),var(--gold-dim)) left bottom/9px 1px no-repeat,
    #|        linear-gradient(var(--gold-dim),var(--gold-dim)) left bottom/1px 9px no-repeat,
    #|        linear-gradient(var(--gold-dim),var(--gold-dim)) right bottom/9px 1px no-repeat,
    #|        linear-gradient(var(--gold-dim),var(--gold-dim)) right bottom/1px 9px no-repeat}
    #|    /* and on a press it lets off one short breath: -- · -- ◆ -- · -- */
    #|    .btn.run .fil{position:absolute;inset:0;pointer-events:none}
    #|    .btn.run .fil .r{position:absolute;left:-7px;right:-7px;height:1px;opacity:0;
    #|      background:
    #|        repeating-linear-gradient(90deg,var(--gold-hi) 0 3px,transparent 3px 6px)
    #|          left center/calc(50% - 6px) 1px no-repeat,
    #|        repeating-linear-gradient(90deg,var(--gold-hi) 0 3px,transparent 3px 6px)
    #|          right center/calc(50% - 6px) 1px no-repeat}
    #|    .btn.run .fil .r.t{top:-5px}
    #|    .btn.run .fil .r.b{top:calc(100% + 5px)}
    #|    .btn.run .fil .k{position:absolute;left:50%;width:4px;height:4px;opacity:0;
    #|      border:1px solid var(--gold-hi);transform:translate(-50%,-50%) rotate(45deg)}
    #|    .btn.run .fil .k.t{top:-5px}
    #|    .btn.run .fil .k.b{top:calc(100% + 5px)}
    #|    .btn.run .fil .s{position:absolute;width:5px;height:5px;opacity:0;
    #|      color:var(--gold-hi);transform:translate(-50%,-50%)}
    #|    .btn.run .fil .s path{fill:none;stroke:currentColor;stroke-width:1.3}
    #|    .btn.run .fil .s.tl{left:-7px;top:-5px}
    #|    .btn.run .fil .s.tr{left:calc(100% + 7px);top:-5px}
    #|    .btn.run .fil .s.bl{left:-7px;top:calc(100% + 5px)}
    #|    .btn.run .fil .s.br{left:calc(100% + 7px);top:calc(100% + 5px)}
    #|    .btn.run.firing{animation:runFlash .95s cubic-bezier(.2,0,.15,1) both}
    #|    .btn.run.firing .fil .r,.btn.run.firing .fil .s{
    #|      animation:filigree .95s cubic-bezier(.2,0,.15,1) both}
    #|    .btn.run.firing .fil .k{animation:filigreeGem .95s cubic-bezier(.2,0,.15,1) both}
    #|    @keyframes runFlash{
    #|      0%{box-shadow:0 0 0 0 transparent}
    #|      18%{box-shadow:0 0 0 2px var(--flash),0 0 14px var(--flash-soft)}
    #|      55%{box-shadow:0 0 0 1px var(--flash-soft),0 0 6px transparent}
    #|      100%{box-shadow:0 0 0 0 transparent}
    #|    }
    #|    @keyframes filigree{0%{opacity:0}16%{opacity:1}52%{opacity:.78}100%{opacity:0}}
    #|    @keyframes filigreeGem{
    #|      0%{opacity:0;transform:translate(-50%,-50%) rotate(0) scale(.35)}
    #|      20%{opacity:1;transform:translate(-50%,-50%) rotate(45deg) scale(1.15)}
    #|      42%{transform:translate(-50%,-50%) rotate(45deg) scale(1)}
    #|      100%{opacity:0;transform:translate(-50%,-50%) rotate(45deg) scale(1)}
    #|    }
    #|    kbd{font-family:var(--mono);font-size:.72em;color:var(--gold);margin-left:.35rem}
    #|    main{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:1px;
    #|      background:var(--hair);background-clip:content-box;
    #|      min-height:0;position:relative;margin:1rem;padding:14px;
    #|      border:1px solid var(--gold-dim);border-radius:2px;
    #|      box-shadow:inset 0 0 80px -36px rgba(201,168,76,.45),0 34px 80px -60px #000}
    #|    /* the same nested frame the documentation uses: the hairline lives in the
    #|       ring of padding, so it never crosses the two panes */
    #|    main::before{content:"";position:absolute;inset:5px;border:1px solid var(--hair);
    #|      border-radius:1px;pointer-events:none;z-index:3}
    #|    main::after{content:"";position:absolute;inset:-4px;pointer-events:none;z-index:3;
    #|      background:
    #|        linear-gradient(var(--gold),var(--gold)) left top/22px 1px no-repeat,
    #|        linear-gradient(var(--gold),var(--gold)) left top/1px 22px no-repeat,
    #|        linear-gradient(var(--gold),var(--gold)) right top/22px 1px no-repeat,
    #|        linear-gradient(var(--gold),var(--gold)) right top/1px 22px no-repeat,
    #|        linear-gradient(var(--gold),var(--gold)) left bottom/22px 1px no-repeat,
    #|        linear-gradient(var(--gold),var(--gold)) left bottom/1px 22px no-repeat,
    #|        linear-gradient(var(--gold),var(--gold)) right bottom/22px 1px no-repeat,
    #|        linear-gradient(var(--gold),var(--gold)) right bottom/1px 22px no-repeat;
    #|      opacity:.85}
    #|    .knot{position:absolute;left:50%;width:6px;height:6px;background:var(--gold);z-index:4;
    #|      transform:translateX(-50%) rotate(45deg);
    #|      box-shadow:0 0 8px rgba(201,168,76,.6)}
    #|    .knot.t{top:-3px} .knot.b{bottom:-3px}
    #|    /* -- · -- runs flanking each knot, the same ruler the panels wear */
    #|    .tick{position:absolute;height:1px;width:min(15%,110px);opacity:.55;pointer-events:none;
    #|      background:repeating-linear-gradient(90deg,var(--gold-dim) 0 3px,transparent 3px 7px)}
    #|    .tick.tl{right:calc(50% + 16px);top:-6px}
    #|    .tick.tr{left:calc(50% + 16px);top:-6px}
    #|    .tick.bl{right:calc(50% + 16px);bottom:-6px}
    #|    .tick.br{left:calc(50% + 16px);bottom:-6px}
    #|    .pane{display:flex;flex-direction:column;min-width:0;min-height:0;position:relative;
    #|      background:
    #|        linear-gradient(180deg,rgba(233,227,212,.04),transparent 22%),
    #|        linear-gradient(180deg,
    #|          color-mix(in oklab,var(--panel-2) 97%,transparent),
    #|          color-mix(in oklab,var(--panel-2) 88%,var(--bg)));
    #|      box-shadow:inset 0 0 60px -50px rgba(201,168,76,.55)}
    #|    .hd{display:flex;align-items:center;gap:.55rem;padding:.55rem .95rem;flex:none;
    #|      border-bottom:1px solid var(--hair);font-family:var(--caps);font-size:.63rem;
    #|      letter-spacing:.22em;text-transform:uppercase;color:rgba(201,168,76,.62)}
    #|    .hd .dot{width:5px;height:5px;background:var(--gold);transform:rotate(45deg);flex:none}
    #|    .pane.r .hd .dot{background:var(--azure)}
    #|    .hd .crumb{margin-left:auto;font-family:var(--mono);font-size:.72rem;letter-spacing:0;
    #|      text-transform:none;color:var(--azure);opacity:0;transition:opacity .16s;
    #|      white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:60%}
    #|    .play[data-focus] .hd .crumb{opacity:1}
    #|    .code{position:relative;flex:1;min-height:0;overflow:hidden}
    #|    .code .mirror,.code textarea{margin:0;border:0;padding:1rem 1.1rem;
    #|      font-family:var(--mono);font-size:.86rem;line-height:1.8;
    #|      white-space:pre-wrap;overflow-wrap:anywhere;tab-size:2}
    #|    .code .mirror{position:absolute;inset:0;pointer-events:none;color:var(--ink)}
    #|    .code textarea{position:absolute;inset:0;width:100%;height:100%;resize:none;
    #|      background:transparent;color:transparent;caret-color:var(--gold-hi);
    #|      outline:none;overflow:auto}
    #|    .code textarea::-webkit-scrollbar{width:0;height:0}
    #|    .code textarea::selection{background:rgba(74,144,217,.3)}
    #|    .code .f{transition:opacity .16s,background .16s}
    #|    .code .p{color:var(--faint)} .code .v{color:var(--azure)}
    #|    .code .n{color:var(--gold)} .code .c{color:var(--faint);font-style:italic}
    #|    /* one scrollbar everywhere: a thin gold hairline, never a grey bar */
    #|    @supports not selector(::-webkit-scrollbar){
    #|      .code textarea{scrollbar-width:none}
    #|      #out,.types,.vars textarea,.doc input{scrollbar-width:thin;
    #|        scrollbar-color:var(--gold-dim) transparent}
    #|    }
    #|    #out::-webkit-scrollbar,.types::-webkit-scrollbar,.vars textarea::-webkit-scrollbar,.doc input::-webkit-scrollbar{width:10px;height:10px}
    #|    #out::-webkit-scrollbar-track,.types::-webkit-scrollbar-track,.vars textarea::-webkit-scrollbar-track,.doc input::-webkit-scrollbar-track{background:transparent}
    #|    #out::-webkit-scrollbar-thumb,.types::-webkit-scrollbar-thumb,.vars textarea::-webkit-scrollbar-thumb,.doc input::-webkit-scrollbar-thumb{
    #|      background:rgba(201,168,76,.4);border:3px solid transparent;background-clip:content-box}
    #|    #out::-webkit-scrollbar-thumb:hover,.types::-webkit-scrollbar-thumb:hover,.vars textarea::-webkit-scrollbar-thumb:hover{
    #|      background:var(--gold-dim);background-clip:content-box}
    #|    #out{margin:0;padding:1rem 1.1rem 2rem;overflow:auto;flex:1;min-height:0;
    #|      font-family:var(--mono);font-size:.82rem;line-height:1.75;white-space:pre;
    #|      color:var(--ink)}
    #|    .ln{position:relative;display:block;padding-left:calc(var(--d,0) * 1.05em + 1rem);
    #|      border-radius:2px;transition:opacity .16s,background .16s}
    #|    .k{color:var(--azure)} .s{color:var(--gold-hi)} .n{color:var(--gold)}
    #|    .q{color:var(--muted);font-style:italic} .p{color:var(--faint)}
    #|    .ln.hot::before,.ln.anc::before{content:"";position:absolute;left:.2rem;top:.15em;
    #|      bottom:.15em;width:1px;background:var(--gold-hi)}
    #|    .ln.anc::before{background:var(--hair)}
    #|    .ln.hot::after{content:attr(data-ann);position:absolute;right:.2rem;top:50%;
    #|      transform:translateY(-50%);font-size:.62rem;letter-spacing:.14em;
    #|      text-transform:uppercase;color:var(--azure);background:var(--panel-2);
    #|      border:1px solid var(--hair);border-radius:2px;padding:.04rem .4rem;
    #|      white-space:nowrap}
    #|    .ln.hot[data-ann=""]::after{content:none}
    #|    .play[data-focus] #out .ln{opacity:.3}
    #|    .play[data-focus] #out .ln.anc{opacity:.62}
    #|    .play[data-focus] #out .ln.hot{opacity:1;background:rgba(201,168,76,.09)}
    #|    .play[data-focus] .code .f{opacity:.3}
    #|    .play[data-focus] .code .f.hot{opacity:1;color:#fff;background:rgba(74,144,217,.34);
    #|      box-shadow:0 0 0 1px rgba(74,144,217,.5);border-radius:2px}
    #|    .vars{flex:none;border-top:1px solid var(--hair);padding:.5rem .95rem .7rem}
    #|    .vars label{display:block;font-family:var(--caps);font-size:.6rem;letter-spacing:.22em;
    #|      text-transform:uppercase;color:rgba(201,168,76,.55);margin-bottom:.3rem}
    #|    .vars textarea{width:100%;height:3.1rem;resize:vertical;background:var(--panel);
    #|      border:1px solid var(--hair);border-radius:2px;color:var(--ink);
    #|      font-family:var(--mono);font-size:.78rem;padding:.35rem .55rem;outline:none}
    #|    .vars textarea:focus{border-color:var(--gold-dim)}
    #|    /* the schema drawer */
    #|    .doc{position:fixed;top:3.4rem;right:0;bottom:0;width:min(24rem,88vw);
    #|      background:var(--panel);border-left:1px solid var(--hair);z-index:5;
    #|      transform:translateX(101%);transition:transform .32s cubic-bezier(.3,0,.2,1);
    #|      display:flex;flex-direction:column}
    #|    /* the shadow belongs to the open drawer: on a translated one it would smear
    #|       a dark band down the right edge of the page */
    #|    .doc[data-open]{transform:none;box-shadow:-40px 0 70px -50px #000}
    #|    .doc .hd{gap:.5rem}
    #|    .doc .hd .btn{margin-left:auto;font-size:.66rem;padding:.12rem .45rem;
    #|      font-family:var(--sans);letter-spacing:0;text-transform:none}
    #|    .doc input{margin:.7rem .95rem 0;background:var(--panel-2);border:1px solid var(--hair);
    #|      border-radius:2px;color:var(--ink);font-family:var(--mono);font-size:.76rem;
    #|      padding:.35rem .55rem;outline:none}
    #|    .doc input:focus{border-color:var(--gold-dim)}
    #|    .types{overflow:auto;padding:.4rem .95rem 2rem;flex:1}
    #|    .types h3{font-family:var(--mono);font-size:.8rem;font-weight:500;color:var(--gold-hi);
    #|      margin:1.1rem 0 .25rem;display:flex;gap:.5rem;align-items:baseline}
    #|    .types h3 span{font-size:.58rem;letter-spacing:.14em;text-transform:uppercase;
    #|      color:var(--faint)}
    #|    .types button{display:flex;gap:.45rem;width:100%;text-align:left;background:none;
    #|      border:0;border-left:1px solid transparent;color:var(--muted);
    #|      font-family:var(--mono);font-size:.75rem;padding:.14rem .4rem;cursor:pointer}
    #|    .types button:hover{color:var(--ink);background:var(--panel-2);
    #|      border-left-color:var(--gold)}
    #|    .types button b{color:var(--azure);font-weight:400}
    #|    .types button i{font-style:normal;color:var(--faint);margin-left:auto}
    #|    .types .empty{color:var(--faint);font-size:.8rem;margin-top:1rem}
    #|    @media (width <= 860px){
    #|      .play{grid-template-rows:auto minmax(0,1fr)}
    #|      .bar{flex-wrap:wrap;gap:.45rem .6rem;padding:.5rem .8rem}
    #|      .name{display:block;font-size:.7rem}
    #|      .sub{display:none}
    #|      .url{max-width:9rem}
    #|      .spacer{display:none}
    #|      .state{margin-left:auto}
    #|      .acts{margin-left:auto}
    #|      main{margin:.45rem;padding:6px}
    #|      main::before{inset:3px}
    #|      main{grid-template-columns:minmax(0,1fr);grid-template-rows:minmax(0,1fr) minmax(0,1fr)}
    #|    }
    #|    /* the day plate: the page follows the reader's system theme */
    #|    @media (prefers-color-scheme: light){
    #|      :root{
    #|        --bg:#ede7d9; --panel:#f7f2e6; --panel-2:#fcf8ef; --abyss-2:#e2d9c6;
    #|        --ink:#211c14; --muted:#635a4c; --faint:#756a5a;
    #|        --gold:#856527; --gold-hi:#946d2c; --hair:rgba(133,101,39,.32);
    #|        --gold-dim:rgba(133,101,39,.42); --azure:#2f6ea8; --crimson:#b23b2e;
    #|        --flash:rgba(133,101,39,.45); --flash-soft:rgba(133,101,39,.24);
    #|      }
    #|      .hd{color:rgba(133,101,39,.85)}
    #|      .vars label{color:rgba(133,101,39,.72)}
    #|      .s{color:#7a5a1f}
    #|      /* the warm end of Run's wash belongs at the foot on the day plate */
    #|      .btn.run{background:linear-gradient(0deg,rgba(133,101,39,.16),transparent)}
    #|      .play[data-focus] .code .f.hot{color:var(--ink);background:rgba(47,110,168,.18)}
    #|      .play[data-focus] #out .ln.hot{background:rgba(133,101,39,.10)}
    #|      /* on parchment the dimmed rows need a little more ink than at night */
    #|      .play[data-focus] #out .ln{opacity:.45}
    #|      .play[data-focus] #out .ln.anc{opacity:.72}
    #|      .play[data-focus] .code .f{opacity:.45}
    #|      .code textarea::selection{background:rgba(47,110,168,.2)}
    #|    }
    #|    @media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
    #|  </style>
    #|</head>
    #|<body>
    #|<div class="play" id="play">
    #|  <header class="bar">
    #|    <svg class="mark" viewBox="0 0 32 32" aria-hidden="true"><rect x="3.5" y="3.5" width="25" height="25" fill="none" stroke="#c9a84c" stroke-width="1"/><rect x="7.5" y="7.5" width="17" height="17" fill="none" stroke="#c9a84c" stroke-width=".6" opacity=".55"/><circle cx="16" cy="16" r="3.2" fill="#e9e3d4"/><circle cx="16" cy="16" r="6.2" fill="none" stroke="#c9a84c" stroke-width=".5" opacity=".45"/></svg>
    #|    <span class="name">moongql</span>
    #|    <span class="sub">GraphQL &middot; MoonBit</span>
    #|    <code class="url" id="url"></code>
    #|    <span class="spacer"></span>
    #|    <span class="state" id="state" aria-live="polite">ready</span>
    #|    <span class="acts">
    #|    <button class="btn" id="docs" aria-expanded="false" aria-controls="doc">Schema</button>
    #|    <button class="btn run" id="run"><span class="fil" aria-hidden="true"><i class="r t"></i><i class="k t"></i><i class="r b"></i><i class="k b"></i><svg class="s tl" viewBox="0 0 12 12" aria-hidden="true"><path d="M6 .9 7.1 4.9 11.1 6 7.1 7.1 6 11.1 4.9 7.1.9 6 4.9 4.9Z"/></svg><svg class="s tr" viewBox="0 0 12 12" aria-hidden="true"><path d="M6 .9 7.1 4.9 11.1 6 7.1 7.1 6 11.1 4.9 7.1.9 6 4.9 4.9Z"/></svg><svg class="s bl" viewBox="0 0 12 12" aria-hidden="true"><path d="M6 .9 7.1 4.9 11.1 6 7.1 7.1 6 11.1 4.9 7.1.9 6 4.9 4.9Z"/></svg><svg class="s br" viewBox="0 0 12 12" aria-hidden="true"><path d="M6 .9 7.1 4.9 11.1 6 7.1 7.1 6 11.1 4.9 7.1.9 6 4.9 4.9Z"/></svg></span>Run<kbd>⌘↵</kbd></button>
    #|    </span>
    #|  </header>
    #|  <main>
    #|    <i class="tick tl" aria-hidden="true"></i><i class="tick tr" aria-hidden="true"></i>
    #|    <i class="tick bl" aria-hidden="true"></i><i class="tick br" aria-hidden="true"></i>
    #|    <span class="knot t" aria-hidden="true"></span>
    #|    <span class="knot b" aria-hidden="true"></span>
    #|    <section class="pane q">
    #|      <div class="hd"><span class="dot"></span>Document</div>
    #|      <div class="code">
    #|        <div class="mirror" id="mirror" aria-hidden="true"></div>
    #|        <textarea id="q" spellcheck="false" autocapitalize="off" autocomplete="off"
    #|          autocorrect="off" aria-label="GraphQL document"># Write an operation, then press ⌘↵ or Run.
    #|{
    #|  __typename
    #|}</textarea>
    #|      </div>
    #|      <div class="vars">
    #|        <label for="vars">Variables</label>
    #|        <textarea id="vars" spellcheck="false" aria-label="Variables as JSON">{}</textarea>
    #|      </div>
    #|    </section>
    #|    <section class="pane r">
    #|      <div class="hd"><span class="dot"></span>Response
    #|        <span class="crumb" id="crumb"></span></div>
    #|      <pre id="out" aria-live="polite"></pre>
    #|    </section>
    #|  </main>
    #|  <aside class="doc" id="doc" aria-hidden="true" aria-label="Schema">
    #|    <div class="hd"><span class="dot"></span>Schema
    #|      <button class="btn" id="doc-close">Close</button></div>
    #|    <input id="filter" placeholder="filter types and fields" aria-label="filter the schema" />
    #|    <div class="types" id="types"><p class="empty">reading the schema…</p></div>
    #|  </aside>
    #|</div>
    #|  <script>
    #|    const ENDPOINT = '
  head
}

///|
/// The rest of the page: the script, once the endpoint literal is closed.
fn gilded_tail() -> String {
  let tail =
    #|';
    #|(function(){
    #|  var play=document.getElementById("play");
    #|  var q=document.getElementById("q");
    #|  var vars=document.getElementById("vars");
    #|  var mirror=document.getElementById("mirror");
    #|  var out=document.getElementById("out");
    #|  var state=document.getElementById("state");
    #|  var crumb=document.getElementById("crumb");
    #|  var doc=document.getElementById("doc");
    #|  var types=document.getElementById("types");
    #|  document.getElementById("url").textContent=ENDPOINT;
    #|
    #|  function esc(t){
    #|    return String(t).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
    #|  }
    #|
    #|  // ---------- the document, painted behind the textarea ----------
    #|  // A textarea cannot hold markup, so the same text is drawn in a div behind
    #|  // it; the textarea keeps the caret, the selection and the undo stack.
    #|  function paint(text){
    #|    var res="",i=0,n=text.length,j,c;
    #|    while(i<n){
    #|      c=text[i];
    #|      if(c==='"'){
    #|        j=i+1;
    #|        while(j<n){ if(text[j]==="\\"){j+=2}else if(text[j]==='"'){j++;break}else{j++} }
    #|        res+='<span class="s">'+esc(text.slice(i,j))+"</span>"; i=j; continue;
    #|      }
    #|      if(c==="#"){
    #|        j=i; while(j<n&&text[j]!=="\n")j++;
    #|        res+='<span class="c">'+esc(text.slice(i,j))+"</span>"; i=j; continue;
    #|      }
    #|      if(/[A-Za-z_]/.test(c)){
    #|        j=i; while(j<n&&/[A-Za-z0-9_]/.test(text[j]))j++;
    #|        var w=text.slice(i,j);
    #|        res+='<span class="f" data-f="'+esc(w)+'">'+esc(w)+"</span>"; i=j; continue;
    #|      }
    #|      if(c==="$"){
    #|        j=i+1; while(j<n&&/[A-Za-z0-9_]/.test(text[j]))j++;
    #|        res+='<span class="v">'+esc(text.slice(i,j))+"</span>"; i=j; continue;
    #|      }
    #|      if(/[0-9]/.test(c)){
    #|        j=i; while(j<n&&/[0-9.eE+-]/.test(text[j]))j++;
    #|        res+='<span class="n">'+esc(text.slice(i,j))+"</span>"; i=j; continue;
    #|      }
    #|      if("{}()[]:,=".indexOf(c)>=0){ res+='<span class="p">'+esc(c)+"</span>"; i++; continue; }
    #|      res+=esc(c); i++;
    #|    }
    #|    mirror.innerHTML=res+"\n";
    #|    rectsDirty=true;
    #|  }
    #|
    #|  // ---------- the response, one line per JSON line ----------
    #|  var root="Query", schema={}, byPath={};
    #|
    #|  function declared(path){
    #|    if(!path||path.indexOf("data.")!==0) return "";
    #|    var segs=path.slice(5).split("."), cur=root, str="";
    #|    for(var i=0;i<segs.length;i++){
    #|      var seg=segs[i].replace(/\[\d+\]/g,"");
    #|      var fields=schema[cur];
    #|      if(!fields||!fields[seg]) return str;
    #|      str=fields[seg];
    #|      cur=str.replace(/[[\]!]/g,"");
    #|    }
    #|    return str;
    #|  }
    #|
    #|  function leaf(v){
    #|    if(v===null) return '<span class="q">null</span>';
    #|    if(typeof v==="string") return '<span class="s">"'+esc(v)+'"</span>';
    #|    if(typeof v==="number") return '<span class="n">'+v+"</span>";
    #|    if(typeof v==="boolean") return '<span class="q">'+v+"</span>";
    #|    return esc(String(v));
    #|  }
    #|
    #|  function line(path,field,depth,html){
    #|    return '<div class="ln" data-path="'+esc(path)+'" data-f="'+esc(field)+'"'+
    #|      ' data-ann="'+esc(declared(path))+'" style="--d:'+depth+'">'+html+"</div>";
    #|  }
    #|
    #|  function render(value){
    #|    var rows=[];
    #|    (function walk(v,key,path,depth,tail,carry){
    #|      var name=key===null?carry:key;
    #|      var at=path?(key===null?path:path+"."+key):(key||"");
    #|      var lead=key===null?"":'<span class="k">"'+esc(key)+'"</span><span class="p">:</span> ';
    #|      if(v===null||typeof v!=="object"){
    #|        rows.push(line(at,name,depth,lead+leaf(v)+tail)); return;
    #|      }
    #|      if(Array.isArray(v)){
    #|        if(!v.length){ rows.push(line(at,name,depth,lead+'<span class="p">[]</span>'+tail)); return; }
    #|        rows.push(line(at,name,depth,lead+'<span class="p">[</span>'));
    #|        for(var i=0;i<v.length;i++)
    #|          walk(v[i],null,at+"["+i+"]",depth+1,i<v.length-1?'<span class="p">,</span>':"",name);
    #|        rows.push(line(at,name,depth,'<span class="p">]</span>'+tail));
    #|        return;
    #|      }
    #|      var keys=Object.keys(v);
    #|      if(!keys.length){ rows.push(line(at,name,depth,lead+'<span class="p">{}</span>'+tail)); return; }
    #|      rows.push(line(at,name,depth,lead+'<span class="p">{</span>'));
    #|      for(var j=0;j<keys.length;j++)
    #|        walk(v[keys[j]],keys[j],at,depth+1,j<keys.length-1?'<span class="p">,</span>':"",name);
    #|      rows.push(line(at,name,depth,'<span class="p">}</span>'+tail));
    #|    })(value,null,"",0,"","");
    #|    return rows.join("");
    #|  }
    #|
    #|  // ---------- lighting a field on both sides ----------
    #|  var rects=[], rectsDirty=true, lastFocus=null;
    #|
    #|  function clearFocus(){
    #|    lastFocus=null;
    #|    play.removeAttribute("data-focus");
    #|    crumb.textContent="";
    #|    Array.prototype.forEach.call(mirror.querySelectorAll(".f.hot"),function(el){
    #|      el.classList.remove("hot");
    #|    });
    #|    Array.prototype.forEach.call(out.querySelectorAll(".ln.hot,.ln.anc"),function(el){
    #|      el.classList.remove("hot","anc");
    #|    });
    #|  }
    #|
    #|  function ancestors(path){
    #|    var parts=path.split("."), res=[];
    #|    for(var i=1;i<parts.length;i++) res.push(parts.slice(0,i).join("."));
    #|    return res;
    #|  }
    #|
    #|  function focus(name,path){
    #|    if(!name){ clearFocus(); return; }
    #|    lastFocus={name:name,path:path||null};
    #|    play.setAttribute("data-focus",name);
    #|    Array.prototype.forEach.call(mirror.querySelectorAll(".f"),function(el){
    #|      el.classList.toggle("hot",el.getAttribute("data-f")===name);
    #|    });
    #|    var lines=out.querySelectorAll(".ln");
    #|    for(var i=0;i<lines.length;i++) lines[i].classList.remove("hot","anc");
    #|    var hits=[];
    #|    if(path&&byPath[path]) hits=byPath[path].slice();
    #|    else for(var k=0;k<lines.length;k++)
    #|      if(lines[k].getAttribute("data-f")===name) hits.push(lines[k]);
    #|    if(!hits.length){ play.removeAttribute("data-focus"); crumb.textContent=""; return; }
    #|    hits.forEach(function(l){
    #|      l.classList.add("hot");
    #|      ancestors(l.getAttribute("data-path")).forEach(function(p){
    #|        var a=byPath[p];
    #|        if(a) a.forEach(function(el){ if(hits.indexOf(el)<0) el.classList.add("anc"); });
    #|      });
    #|    });
    #|    crumb.textContent=(hits.length>1?hits.length+" lines · ":"")+
    #|      (path||hits[0].getAttribute("data-path")).replace(/^data\./,"");
    #|  }
    #|
    #|  function cacheRects(){
    #|    rects=[];
    #|    Array.prototype.forEach.call(mirror.querySelectorAll(".f"),function(el){
    #|      rects.push({el:el,r:el.getBoundingClientRect()});
    #|    });
    #|    rectsDirty=false;
    #|  }
    #|
    #|  function tokenAt(x,y){
    #|    for(var i=0;i<rects.length;i++){
    #|      var r=rects[i].r;
    #|      if(x>=r.left-1&&x<=r.right+1&&y>=r.top-1&&y<=r.bottom+1) return rects[i].el;
    #|    }
    #|    return null;
    #|  }
    #|
    #|  function show(parsed){
    #|    out.innerHTML=render(parsed);
    #|    byPath={};
    #|    Array.prototype.forEach.call(out.querySelectorAll(".ln"),function(l){
    #|      var p=l.getAttribute("data-path");
    #|      if(!p) return;
    #|      (byPath[p]||(byPath[p]=[])).push(l);
    #|    });
    #|    if(lastFocus) focus(lastFocus.name,lastFocus.path);
    #|  }
    #|
    #|  // the button lets off one breath on every press
    #|  function fire(){
    #|    var b=document.getElementById("run");
    #|    if(!b) return;
    #|    b.classList.remove("firing");
    #|    void b.offsetWidth;
    #|    b.classList.add("firing");
    #|    clearTimeout(b.fireT);
    #|    b.fireT=setTimeout(function(){ b.classList.remove("firing") },950);
    #|  }
    #|
    #|  // ---------- running an operation ----------
    #|  function run(){
    #|    fire();
    #|    var payload={query:q.value};
    #|    var raw=vars.value.trim();
    #|    if(raw&&raw!=="{}"){
    #|      try{ payload.variables=JSON.parse(raw) }
    #|      catch(e){
    #|        state.textContent="variables are not JSON"; state.className="state bad";
    #|        out.textContent="the variables box is not valid JSON:\n\n"+String(e);
    #|        return;
    #|      }
    #|    }
    #|    state.textContent="running…"; state.className="state";
    #|    var t0=performance.now();
    #|    fetch(ENDPOINT,{
    #|      method:"POST",
    #|      headers:{"content-type":"application/json","accept":"application/json"},
    #|      body:JSON.stringify(payload)
    #|    }).then(function(r){
    #|      return r.text().then(function(text){ return {status:r.status,text:text} });
    #|    }).then(function(res){
    #|      var ms=Math.round(performance.now()-t0);
    #|      var parsed;
    #|      try{ parsed=JSON.parse(res.text) }
    #|      catch(e){
    #|        state.textContent=res.status+" · not JSON"; state.className="state bad";
    #|        out.textContent=res.text;
    #|        return;
    #|      }
    #|      var bad=parsed.errors&&parsed.errors.length>0;
    #|      state.textContent=res.status+" · "+ms+" ms";
    #|      state.className="state "+(bad?"bad":"ok");
    #|      show(parsed);
    #|    }).catch(function(e){
    #|      state.textContent="the request did not go through"; state.className="state bad";
    #|      out.textContent=String(e);
    #|    });
    #|  }
    #|
    #|  // ---------- the schema drawer ----------
    #|  var INTRO="{ __schema { types { name kind fields { name type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } } }";
    #|
    #|  function typeName(t){
    #|    if(!t) return "?";
    #|    if(t.kind==="NON_NULL") return typeName(t.ofType)+"!";
    #|    if(t.kind==="LIST") return "["+typeName(t.ofType)+"]";
    #|    return t.name||"?";
    #|  }
    #|
    #|  function insert(name){
    #|    var s=q.selectionStart, e=q.selectionEnd, v=q.value;
    #|    q.value=v.slice(0,s)+name+v.slice(e);
    #|    q.focus();
    #|    q.selectionStart=q.selectionEnd=s+name.length;
    #|    paint(q.value);
    #|  }
    #|
    #|  function readSchema(){
    #|    fetch(ENDPOINT,{
    #|      method:"POST",
    #|      headers:{"content-type":"application/json","accept":"application/json"},
    #|      body:JSON.stringify({query:INTRO})
    #|    }).then(function(r){ return r.json() })
    #|      .then(function(res){
    #|        if(!res.data||!res.data.__schema){
    #|          types.innerHTML='<p class="empty">the endpoint answered no schema</p>';
    #|          return;
    #|        }
    #|        var list=res.data.__schema.types.filter(function(t){
    #|          return t.name.indexOf("__")!==0;
    #|        });
    #|        list.forEach(function(t){
    #|          if(!t.fields) return;
    #|          var f={};
    #|          t.fields.forEach(function(x){ f[x.name]=typeName(x.type) });
    #|          schema[t.name]=f;
    #|        });
    #|        types.innerHTML=list.map(function(t){
    #|          var rows=(t.fields||[]).map(function(f){
    #|            return '<button data-name="'+esc(f.name)+'"><b>'+esc(f.name)+
    #|              "</b><i>"+esc(typeName(f.type))+"</i></button>";
    #|          }).join("");
    #|          // a scalar has no fields, so it gets a heading and nothing else
    #|          return "<h3>"+esc(t.name)+"<span>"+t.kind.toLowerCase()+"</span></h3>"+rows;
    #|        }).join("");
    #|      }).catch(function(){
    #|        types.innerHTML='<p class="empty">the schema could not be read</p>';
    #|      });
    #|  }
    #|
    #|  // ---------- wiring ----------
    #|  document.getElementById("run").addEventListener("click",run);
    #|  var open=false;
    #|  function toggleDoc(next){
    #|    open=next;
    #|    if(open) doc.setAttribute("data-open","");
    #|    else doc.removeAttribute("data-open");
    #|    doc.setAttribute("aria-hidden",open?"false":"true");
    #|    document.getElementById("docs").setAttribute("aria-expanded",open?"true":"false");
    #|    if(open&&!types.querySelector("h3")) readSchema();
    #|  }
    #|  document.getElementById("docs").addEventListener("click",function(){ toggleDoc(!open) });
    #|  document.getElementById("doc-close").addEventListener("click",function(){ toggleDoc(false) });
    #|  document.getElementById("filter").addEventListener("input",function(ev){
    #|    var s=ev.target.value.toLowerCase();
    #|    Array.prototype.forEach.call(types.querySelectorAll("h3,button"),function(el){
    #|      var hit=!s||el.textContent.toLowerCase().indexOf(s)>=0;
    #|      el.style.display=hit?"":"none";
    #|    });
    #|  });
    #|  types.addEventListener("click",function(ev){
    #|    var b=ev.target.closest("button[data-name]");
    #|    if(b) insert(b.getAttribute("data-name"));
    #|  });
    #|  q.addEventListener("keydown",function(ev){
    #|    if((ev.metaKey||ev.ctrlKey)&&ev.key==="Enter"){ ev.preventDefault(); run(); }
    #|  });
    #|  q.addEventListener("input",function(){ paint(q.value) });
    #|  addEventListener("resize",function(){ rectsDirty=true },{passive:true});
    #|  q.addEventListener("scroll",function(){
    #|    mirror.style.transform="translateY("+(-q.scrollTop)+"px)";
    #|    rectsDirty=true;
    #|  },{passive:true});
    #|  q.addEventListener("mousemove",function(ev){
    #|    if(rectsDirty) cacheRects();
    #|    var el=tokenAt(ev.clientX,ev.clientY);
    #|    if(el) focus(el.getAttribute("data-f"),null); else clearFocus();
    #|  });
    #|  q.addEventListener("mouseleave",clearFocus);
    #|  out.addEventListener("mouseover",function(ev){
    #|    var l=ev.target.closest(".ln");
    #|    if(l) focus(l.getAttribute("data-f"),l.getAttribute("data-path"));
    #|  });
    #|  out.addEventListener("mouseleave",clearFocus);
    #|  paint(q.value);
    #|  readSchema();
    #|  run();
    #|})();
    #|  </script>
    #|</body>
    #|</html>
  tail
}

///|
/// The gilded page, wired to `endpoint`. The endpoint may be relative: the page
/// is served by the endpoint it talks to, so a relative path is the normal case.
fn gilded_page(endpoint : String) -> String {
  gilded_head() + endpoint + gilded_tail()
}
