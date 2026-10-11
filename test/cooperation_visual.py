"""Require a painted physical cooperation card before native clicks."""
from desktop_harness import *
from PIL import Image


def visible_cooperation(get_status, name, label, predicate=lambda row: True):
    def rendered():
        state=get_status()
        if not state['visible'] or state['output']!='human':return None
        row=next((row for row in state['controls'] if row['name']==name and predicate(row)),None)
        if not row:return None
        layers=[layer for rows in ctl('layers',True)['human']['levels'].values() for layer in rows
                if layer['namespace']=='cornice-desktop-cooperation' and layer['alpha']>0 and layer['w']>24 and layer['h']>24]
        if not layers:return None
        layer=layers[-1]
        path=BASE/(label+'.png')
        subprocess.run(['grim','-o','human',str(path)],env=ENV,check=True,timeout=4)
        with Image.open(path) as source:
            image=source.convert('RGB')
            x,y,w,h=[round(layer[key]) for key in ('x','y','w','h')]
            pairs=[((x+6,y+h//2),(x-6,y+h//2)),((x+w-7,y+h//2),(x+w+6,y+h//2)),
                   ((x+w//2,y+h-7),(x+w//2,y+h+6))]
            contrast=sum(max(abs(a-b) for a,b in zip(image.getpixel(inner),image.getpixel(outer)))>40
                         for inner,outer in pairs if all(0<=px<image.width and 0<=py<image.height for px,py in (inner,outer)))
            # These suites use actual light GTK clients behind the opaque card.
            # Logical visibility or a mapped invisible secondary layer cannot
            # satisfy the physical framebuffer edge contrast.
            pixels=image.crop((x,y,x+w,y+h))
            varied=len(pixels.getcolors(w*h) or [])>20
        (BASE/(label+'.json')).write_text(json.dumps({'state':state,'row':row,'layer':layer,'contrastingEdges':contrast,'paintedText':varied}))
        return (row,layer) if contrast>=2 and varied else None
    return wait(rendered)
