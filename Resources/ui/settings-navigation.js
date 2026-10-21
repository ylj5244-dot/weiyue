(function(root){
  'use strict';
  root.ReaderSettingsNavigation={mount(options){
    const dialog=options.dialog,host=options.host,panels=options.panels;
    const buttons=Array.from(dialog.querySelectorAll('[data-settings-category]'));
    let active='reading';
    for(const [key,panel] of Object.entries(panels)){
      panel.classList.add('settings-embedded');panel.hidden=true;panel.inert=true;panel.setAttribute('role','tabpanel');panel.setAttribute('aria-labelledby',buttons.find(b=>b.dataset.settingsCategory===key).id);host.append(panel);
      if(panel.tagName==='DIALOG')panel.addEventListener('close',()=>{if(dialog.open&&!panel.open&&!panel.hidden)dialog.close();});
    }
    function select(key){
      if(!panels[key]||options.isBusy())return false;
      active=key;
      buttons.forEach(button=>{const chosen=button.dataset.settingsCategory===key;button.setAttribute('aria-selected',String(chosen));button.tabIndex=chosen?0:-1;});
      Object.entries(panels).forEach(([name,panel])=>{panel.hidden=name!==key;panel.inert=name!==key;});
      options.activate(key,panels[key]);return true;
    }
    buttons.forEach((button,index)=>{
      button.setAttribute('aria-controls',panels[button.dataset.settingsCategory].id);
      button.addEventListener('click',()=>select(button.dataset.settingsCategory));
      button.addEventListener('keydown',event=>{
        if(!['ArrowUp','ArrowDown','Home','End'].includes(event.key))return;
        event.preventDefault();const available=buttons.filter(b=>!b.disabled);const i=available.indexOf(button);
        const next=event.key==='Home'?available[0]:event.key==='End'?available.at(-1):available[(i+(event.key==='ArrowDown'?1:-1)+available.length)%available.length];
        if(next){next.click();next.focus();}
      });
    });
    dialog.addEventListener('cancel',event=>{if(options.isBusy())event.preventDefault();});
    dialog.addEventListener('close',()=>{
      Object.values(panels).forEach(panel=>{panel.hidden=true;panel.inert=true;if(panel.tagName==='DIALOG'&&panel.open)panel.close();});
    });
    return {select,current:()=>active};
  }};
})(window);
