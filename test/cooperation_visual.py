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


def visible_cooperation_menu(get_geometry, move, name, label, expected_label, scroll=None):
    """Open the real bar menu on the shell that currently owns physical input."""
    def controls():
        return next(widget['controls'] for widget in get_geometry() if widget['id']=='cn.agent-desktop')
    icon=next(item for item in controls() if item['name'] in ('group','status'))
    move(icon['x']+icon['width']/2,icon['y']+icon['height']/2)
    last_geometry=None;stable_since=0
    def rendered():
        nonlocal last_geometry,stable_since
        rows=controls()
        action=next((item for item in rows if item.get('scope')=='cooperation' and item.get('target')==name
                     and item.get('label')==expected_label and item['enabled']),None)
        heading=next((item for item in rows if item.get('scope')=='cooperation' and item.get('target')==name
                      and item.get('kind')=='section'),None)
        if not action or not heading:return None
        layers=[layer for levels in ctl('layers',True)['human']['levels'].values() for layer in levels
                if layer['namespace']=='cornice-desktop-menu' and layer['alpha']>0 and layer['w']>24 and layer['h']>24]
        if not layers:return None
        layer=layers[-1]
        if not (layer['x']<=action['x']<layer['x']+layer['w'] and layer['y']<=action['y']
                and action['y']+action['height']<=layer['y']+layer['h']):
            last_geometry=None;stable_since=0
            if scroll:
                move(layer['x']+layer['w']/2,layer['y']+layer['h']/2)
                scroll(-10 if action['y']<layer['y'] else 10)
            return None
        # Native wheel scrolling can keep Flickable moving after the row first
        # enters the viewport. Do not click a stale coordinate or during a flick.
        geometry=(round(action['x'],1),round(action['y'],1),round(action['height'],1),layer['x'],layer['y'])
        if geometry!=last_geometry:
            last_geometry=geometry;stable_since=time.monotonic();return None
        if time.monotonic()-stable_since<.6:return None
        path=BASE/(label+'.png')
        subprocess.run(['grim','-o','human',str(path)],env=ENV,check=True,timeout=4)
        with Image.open(path) as source:
            image=source.convert('RGB')
            x,y,w,h=[round(layer[key]) for key in ('x','y','w','h')]
            varied=len(image.crop((x,y,x+w,y+h)).getcolors(w*h) or [])>20
        (BASE/(label+'.json')).write_text(json.dumps({'rows':rows,'action':action,'heading':heading,'layer':layer,'paintedText':varied}))
        return (action,heading,layer) if varied else None
    return wait(rendered)


def assert_painted_cooperation_tail(layer, heading, label, marker):
    """Read the marker from actual pixels, not the full source string in IPC.

    This graphical regression requires the tesseract executable on the test
    host; it is a developer-test dependency, not a Cornice runtime dependency.
    """
    assert heading['fullDetail'] and heading['detailLineCount']>8 and not heading['detailTruncated'],heading
    image_path=BASE/(label+'.png')
    subprocess.run(['grim','-o','human',str(image_path)],env=ENV,check=True,timeout=4)
    from PIL import ImageOps
    with Image.open(image_path) as source:
        x,y,w,h=[round(layer[key]) for key in ('x','y','w','h')]
        crop=ImageOps.invert(source.convert('L').crop((x,y,x+w,y+h)))
        crop=crop.resize((w*2,h*2))
        crop_path=BASE/(label+'-menu.png');crop.save(crop_path)
    # A menu contains independent text blocks, rather than one prose paragraph.
    result=subprocess.run(['tesseract',str(crop_path),'stdout','--psm','11','-l','eng'],capture_output=True,text=True,timeout=10)
    (BASE/(label+'-ocr.txt')).write_text(result.stdout)
    (BASE/(label+'-ocr-stderr.txt')).write_text(result.stderr)
    assert result.returncode==0,('Tesseract OCR failed: this developer test requires tesseract-data-eng; a read-only trained-data directory may be selected with TESSDATA_PREFIX.',result.returncode,result.stderr)
    compact=lambda text:''.join(c for c in text.upper() if c.isalnum())
    assert compact(marker) in compact(result.stdout),(marker,result.stdout,heading)


def require_cooperation_ocr():
    """Fail before graphical setup when the declared OCR test data is missing."""
    result=subprocess.run(['tesseract','--list-langs'],capture_output=True,text=True,timeout=5)
    (BASE/'ocr-languages.txt').write_text(result.stdout+'\n'+result.stderr)
    assert result.returncode==0 and 'eng' in result.stdout.splitlines(),(
        'This developer test requires tesseract and English trained data (Arch: tesseract-data-eng; '
        '/usr/share/tessdata/eng.traineddata), or a read-only directory selected with TESSDATA_PREFIX.',
        result.returncode,result.stdout,result.stderr)
