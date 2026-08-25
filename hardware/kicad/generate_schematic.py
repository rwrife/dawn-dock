#!/usr/bin/env python3
"""Generate the editable Dawn Dock Rev A carrier schematic.

The generated .kicad_sch is the source of truth. Project-local symbols and
footprints are generated from the manufacturer pin tables/drawings cited in
hardware/kicad/README.md. This script makes review/re-generation repeatable;
it does not claim PCB, assembly, or bench validation.
"""
from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

OBSERVED = "2026-08-23"
RES_DS = "https://www.yageo.com/upload/media/product/productsearch/datasheet/rchip/PYu-RC_Group_51_RoHS_L_12.pdf"
CAP_DS = "https://www.murata.com/en-global/products/capacitor/mlcc/overview/lineup"


def find_symbol_dir(explicit: str | None) -> Path:
    for candidate in (explicit, os.environ.get("KICAD_SYMBOL_DIR"), "/usr/share/kicad/symbols"):
        if candidate and Path(candidate).is_dir():
            return Path(candidate)
    raise SystemExit("KiCad symbol libraries not found; pass --symbol-dir")


def q(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def custom_symbol(name: str, ref: str, footprint: str, datasheet: str,
                  description: str, pins: list[tuple[str, str, str, str]]) -> str:
    left = [p for p in pins if p[3] == "L"]
    right = [p for p in pins if p[3] == "R"]
    top = [p for p in pins if p[3] == "T"]
    bottom = [p for p in pins if p[3] == "B"]
    rows = max(len(left), len(right), 4)
    half_h = max(7.62, (rows + 1) * 1.27)
    half_w = 15.24
    out = [f'  (symbol "{q(name)}" (pin_names (offset 1.016)) (in_bom yes) (on_board yes)',
           f'    (property "Reference" "{q(ref)}" (at {-half_w} {half_h + 2.54} 0) (effects (font (size 1.27 1.27)) (justify left bottom)))',
           f'    (property "Value" "{q(name)}" (at {half_w} {-half_h - 2.54} 0) (effects (font (size 1.27 1.27)) (justify right top)))',
           f'    (property "Footprint" "{q(footprint)}" (at 0 {-half_h - 5.08} 0) (effects (font (size 1.27 1.27)) hide))',
           f'    (property "Datasheet" "{q(datasheet)}" (at 0 {-half_h - 7.62} 0) (effects (font (size 1.27 1.27)) hide))',
           f'    (property "ki_description" "{q(description)}" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))',
           f'    (symbol "{q(name)}_0_1" (rectangle (start {-half_w} {half_h}) (end {half_w} {-half_h}) (stroke (width 0.254) (type default)) (fill (type background))))',
           f'    (symbol "{q(name)}_1_1"']
    def pin_line(pin: tuple[str, str, str, str], idx: int, count: int) -> str:
        number, pname, ptype, side = pin
        if side == "L":
            x, y, angle = -half_w - 5.08, (count - 1 - 2 * idx) * 1.27, 0
        elif side == "R":
            x, y, angle = half_w + 5.08, (count - 1 - 2 * idx) * 1.27, 180
        elif side == "T":
            x, y, angle = (idx - (count - 1) / 2) * 3.81, half_h + 5.08, 270
        else:
            x, y, angle = (idx - (count - 1) / 2) * 3.81, -half_h - 5.08, 90
        shape = "inverted" if pname.endswith("_N") or pname.startswith("~") else "line"
        return (f'      (pin {ptype} {shape} (at {x:.3f} {y:.3f} {angle}) (length 5.08) '
                f'(name "{q(pname)}" (effects (font (size 1.016 1.016)))) '
                f'(number "{q(number)}" (effects (font (size 1.016 1.016)))))')
    for side_list in (left, right, top, bottom):
        for idx, pin in enumerate(side_list):
            out.append(pin_line(pin, idx, len(side_list)))
    out += ["    )", "  )"]
    return "\n".join(out)


def write_custom_library(here: Path) -> None:
    lib = here / "lib"
    pretty = lib / "dawn-dock.pretty"
    pretty.mkdir(parents=True, exist_ok=True)
    symbols: list[str] = []
    # Official v1.1 J1/J3 header map. Pin numbers preserve header identity.
    j1_names = ["3V3", "3V3", "CHIP_PU", "GPIO4", "GPIO5", "GPIO6", "GPIO7", "GPIO15", "GPIO16", "GPIO17", "GPIO18", "GPIO8", "GPIO3", "GPIO46", "GPIO9", "GPIO10", "GPIO11", "GPIO12", "GPIO13", "GPIO14", "5V", "GND"]
    j3_names = ["GND", "GPIO43", "GPIO44", "GPIO1", "GPIO2", "GPIO42", "GPIO41", "GPIO40", "GPIO39", "GPIO38", "GPIO37", "GPIO36", "GPIO35", "GPIO0", "GPIO45", "GPIO48", "GPIO47", "GPIO21", "GPIO20", "GPIO19", "GND", "GND"]
    devkit_pins = [(f"J1-{i}", n, "passive", "L") for i, n in enumerate(j1_names, 1)] + [(f"J3-{i}", n, "passive", "R") for i, n in enumerate(j3_names, 1)]
    symbols.append(custom_symbol("ESP32-S3-DEVKITC-1-N8R8", "A", "dawn-dock:ESP32-S3-DevKitC-1_Socket", "https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s3/esp32-s3-devkitc-1/user_guide_v1.1.html", "Espressif ESP32-S3-DevKitC-1 v1.1 N8R8 module, official two 22-pin header map", devkit_pins))
    display_names = ["VCC", "GND", "MISO", "MOSI", "SCLK", "LCD_CS", "LCD_DC", "LCD_RST", "LCD_BL", "TP_SDA", "TP_SCL", "TP_INT", "TP_RST", "SD_CS", "3V3"]
    symbols.append(custom_symbol("Waveshare-29318", "DS", "Connector_PinSocket_2.54mm:PinSocket_1x15_P2.54mm_Vertical", "https://www.waveshare.com/wiki/3.5inch_Capacitive_Touch_LCD", "Waveshare 3.5 inch capacitive touch LCD SKU 29318 15-pin terminal interface", [(str(i), n, "passive", "L" if i <= 8 else "R") for i, n in enumerate(display_names, 1)]))
    symbols.append(custom_symbol("TPS259531", "U", "Package_SON:WSON-8-1EP_2x2mm_P0.5mm_EP0.9x1.6mm_ThermalVias", "https://www.ti.com/lit/ds/symlink/tps2595.pdf", "TI TPS259531 5.7V-clamp eFuse, DSG WSON-8 exposed pad", [("1", "dVdt", "input", "L"), ("2", "EN/UVLO", "input", "L"), ("3", "IN", "power_in", "L"), ("4", "IN", "power_in", "L"), ("5", "OUT", "power_out", "R"), ("6", "FLT_N", "open_collector", "R"), ("7", "ILM", "input", "R"), ("8", "GND", "power_in", "R"), ("9", "EP_GND", "power_in", "B")]))
    symbols.append(custom_symbol("SN74LVC14APWR", "U", "Package_SO:TSSOP-14_4.4x5mm_P0.65mm", "https://www.ti.com/lit/ds/symlink/sn74lvc14a.pdf", "TI hex Schmitt-trigger inverter, 1.65V to 3.6V supply, 5V-tolerant inputs", [("1", "1A", "input", "L"), ("3", "2A", "input", "L"), ("5", "3A", "input", "L"), ("9", "4A", "input", "L"), ("11", "5A", "input", "L"), ("13", "6A", "input", "L"), ("7", "GND", "power_in", "B"), ("2", "1Y", "output", "R"), ("4", "2Y", "output", "R"), ("6", "3Y", "output", "R"), ("8", "4Y", "output", "R"), ("10", "5Y", "output", "R"), ("12", "6Y", "output", "R"), ("14", "VCC", "power_in", "T")]))
    symbols.append(custom_symbol("Adafruit-3006", "A", "dawn-dock:Adafruit_3006_MAX98357A", "https://learn.adafruit.com/adafruit-max98357-i2s-class-d-mono-amp/pinouts", "Adafruit 3006 MAX98357A I2S class-D mono amplifier breakout", [("1", "VIN", "power_in", "L"), ("2", "GND", "power_in", "L"), ("3", "BCLK", "input", "L"), ("4", "LRC", "input", "L"), ("5", "DIN", "input", "L"), ("6", "GAIN", "input", "L"), ("7", "SD", "input", "L"), ("8", "SPK+", "output", "R"), ("9", "SPK-", "output", "R")]))
    symbols.append(custom_symbol("Adafruit-4162", "A", "dawn-dock:Adafruit_4162_VEML7700", "https://www.adafruit.com/product/4162", "Adafruit 4162 VEML7700 ambient-light breakout", [("1", "VIN", "power_in", "L"), ("2", "GND", "power_in", "L"), ("3", "3Vo", "power_out", "R"), ("4", "SCL", "input", "L"), ("5", "SDA", "bidirectional", "L")]))
    symbols.append(custom_symbol("PEC11R-4215F-S0024", "ENC", "dawn-dock:PEC11R-4xxxF-Sxxxx", "https://www.bourns.com/docs/product-datasheets/pec11r.pdf", "Bourns PEC11R 12mm incremental encoder, A/C/B and momentary switch", [("A", "A", "passive", "L"), ("C", "COMMON", "passive", "L"), ("B", "B", "passive", "L"), ("1", "SW1", "passive", "R"), ("2", "SW2", "passive", "R")]))
    symbols.append(custom_symbol("Keystone-3003-CR2032", "BT", "dawn-dock:Keystone_3003_CR2032", "https://www.limpulsion.fr/upload/docs/KEYSTONE3003_1.PDF", "CR2032 primary cell in Keystone 3003 through-hole retainer with PCB negative contact", [("1", "+", "passive", "L"), ("2", "-", "passive", "R")]))
    symbols.append(custom_symbol("Speaker-8R-2W", "SPK", "", "https://www.waveshare.com/8ohm-2w-speaker-b.htm", "Waveshare 27859 8 ohm 2 watt enclosed speaker, off-board", [("1", "+", "passive", "L"), ("2", "-", "passive", "L")]))
    (lib / "dawn-dock.kicad_sym").write_text("(kicad_symbol_lib (version 20220914) (generator kicad_symbol_editor)\n" + "\n".join(symbols) + "\n)\n", encoding="utf-8")

    def footprint(name: str, description: str, pads: list[tuple[str, float, float, str]], outline: tuple[float, float, float, float]) -> None:
        x1, y1, x2, y2 = outline
        rows = [f'(footprint "{name}" (version 20221018) (generator pcbnew)', '  (layer "F.Cu")', f'  (descr "{q(description)}")', '  (attr through_hole)', '  (fp_text reference "REF**" (at 0 -4) (layer "F.SilkS") (effects (font (size 1 1) (thickness 0.15))))', '  (fp_text value "'+q(name)+'" (at 0 4) (layer "F.Fab") (effects (font (size 1 1) (thickness 0.15))))']
        for a,b,c,d in [(x1,y1,x2,y1),(x2,y1,x2,y2),(x2,y2,x1,y2),(x1,y2,x1,y1)]:
            rows.append(f'  (fp_line (start {a} {b}) (end {c} {d}) (stroke (width 0.25) (type default)) (layer "F.SilkS"))')
        for num, x, y, kind in pads:
            shape = "rect" if num in {"1", "J1-1"} else "circle"
            if kind == "smd": rows.append(f'  (pad "{num}" smd {shape} (at {x} {y}) (size 4 4) (layers "F.Cu" "F.Paste" "F.Mask"))')
            elif kind == "npth": rows.append(f'  (pad "" np_thru_hole circle (at {x} {y}) (size 2.2 2.2) (drill 2.2) (layers "*.Cu" "*.Mask"))')
            else: rows.append(f'  (pad "{num}" thru_hole {shape} (at {x} {y}) (size 1.8 1.8) (drill 1) (layers "*.Cu" "*.Mask"))')
        rows.append(')')
        (pretty / f"{name}.kicad_mod").write_text("\n".join(rows)+"\n", encoding="utf-8")

    devpads=[]
    for i in range(1,23):
        y=-26.67+(i-1)*2.54
        devpads += [(f"J1-{i}",-12.7,y,"tht"),(f"J3-{i}",12.7,y,"tht")]
    footprint("ESP32-S3-DevKitC-1_Socket", "Two 1x22 2.54mm socket rows for Espressif ESP32-S3-DevKitC-1 v1.1; 25.4mm row spacing, antenna end at negative Y", devpads, (-14.0,-31.37,14.0,31.37))
    footprint("Adafruit_3006_MAX98357A", "Adafruit 3006 carrier interface; 2.54mm signal header plus speaker breakout pads", [(str(i),-7.62+(i-1)*2.54,5.08,"tht") for i in range(1,8)] + [("8",-2.54,-5.08,"tht"),("9",2.54,-5.08,"tht")], (-9.7,-8.9,9.7,8.9))
    footprint("Adafruit_4162_VEML7700", "Adafruit 4162 VEML7700 breakout 1x5 2.54mm carrier header", [(str(i),-5.08+(i-1)*2.54,0,"tht") for i in range(1,6)], (-8,-10,8,10))
    footprint("PEC11R-4xxxF-Sxxxx", "Bourns PEC11R-4xxxF-Sxxxx vertical encoder with switch; mounting pattern from PEC11R drawing", [("A",-5,7.5,"tht"),("C",0,7.5,"tht"),("B",5,7.5,"tht"),("1",-2.5,-7.5,"tht"),("2",2.5,-7.5,"tht"),("",-7.5,0,"npth"),("",7.5,0,"npth")], (-7,-7,7,7))
    footprint("Keystone_3003_CR2032", "Keystone 3003 THM retainer for CR2032; 21.1mm retainer width, 22.6mm envelope, PCB negative contact", [("1",-10.55,0,"tht"),("1",10.55,0,"tht"),("2",0,0,"smd")], (-11.3,-9.95,11.3,9.95))


def main() -> int:
    parser=argparse.ArgumentParser()
    parser.add_argument("--symbol-dir")
    parser.add_argument("--output", default=str(Path(__file__).with_name("dawn-dock.kicad_sch")))
    args=parser.parse_args()
    here=Path(__file__).resolve().parent
    write_custom_library(here)
    symbol_dir=find_symbol_dir(args.symbol_dir)
    os.environ["KICAD_SYMBOL_DIR"]=str(symbol_dir)
    from kicad_sch_api import create_schematic, get_symbol_cache
    cache=get_symbol_cache(); cache.discover_libraries([str(symbol_dir)])
    if not cache.add_library_path(str(here/"lib"/"dawn-dock.kicad_sym")):
        raise SystemExit("Could not load project symbol library")
    sch=create_schematic("Dawn Dock Rev A carrier")
    sch.set_paper_size("A3")
    sch.set_title_block(title="Dawn Dock USB/SELV carrier", date="2026-08-25", rev="A0 schematic", company="Open hardware design — rwrife/dawn-dock", comments={1:"USB 5V SELV only; no mains; not medical/life-safety",2:"CR2032 primary cell: DO NOT CHARGE",3:"Static schematic only; PCB/assembly/bench validation pending"})
    comps={}; labels=set(); ncs=set(); ref_counters={}; dnp_refs=set()
    def add(lib_id,ref,value,pos,footprint,manufacturer,mpn,supplier,supplier_pn,datasheet,cost,notes,*,in_bom=True,dnp=False):
        functional_ref = ref
        if re.fullmatch(r"[A-Za-z#]+[0-9]+", ref):
            kicad_ref = ref
        else:
            prefix = re.match(r"[A-Za-z#]+", ref).group().split("_")[0]
            ref_counters[prefix] = ref_counters.get(prefix, 0) + 1
            while f"{prefix}{ref_counters[prefix]}" in {getattr(x, "reference", "") for x in comps.values()}:
                ref_counters[prefix] += 1
            kicad_ref = f"{prefix}{ref_counters[prefix]}"
        c=sch.components.add(lib_id,kicad_ref,value,position=pos,footprint=footprint)
        for k,v in {"Manufacturer":manufacturer,"MPN":mpn,"Supplier":supplier,"Supplier PN":supplier_pn,"Datasheet":datasheet,"Estimated Unit Cost USD":cost,"Price Observed UTC":OBSERVED,"Cost Basis":"Dated planning estimate; recheck price/stock before order","BOM Comments":notes}.items(): c.set_property(k,v)
        if functional_ref != kicad_ref:
            c.set_property("Functional Reference", functional_ref)
        c.in_bom=in_bom
        if dnp:
            dnp_refs.add(kicad_ref)
        comps[ref]=c; return c
    def point(ref,pin):
        from kicad_sch_api.core.types import Point
        c=comps[ref]; p=c.get_pin(str(pin))
        if p is None: raise ValueError(f"{ref} pin {pin} missing")
        return Point(c.position.x+p.position.x,c.position.y-p.position.y)
    def connect(ref,pin,net):
        p=point(ref,pin); key=(round(p.x,6),round(p.y,6),net)
        if key not in labels: sch.labels.add(net,(p.x,p.y)); labels.add(key)
    def nc(ref,pin):
        p=point(ref,pin); key=(round(p.x,6),round(p.y,6))
        if key not in ncs: sch.no_connects.add((p.x,p.y)); ncs.add(key)
    def passive(ref,value,pos,mpn,cost,notes,kind="R",footprint=None):
        fp=footprint or ("Resistor_SMD:R_0603_1608Metric" if kind=="R" else "Capacitor_SMD:C_0603_1608Metric")
        return add(f"Device:{kind}",ref,value,pos,fp,"Yageo" if kind=="R" else "Murata",mpn,"DigiKey",mpn,RES_DS if kind=="R" else CAP_DS,cost,notes)

    # USB-C sink and protected 5V power tree.
    add("Connector:USB_C_Receptacle_USB2.0_16P","J_PWR1","USB-C POWER ONLY",(32,45),"Connector_USB:USB_C_Receptacle_GCT_USB4105-xx-A_16P_TopMnt_Horizontal","Global Connector Technology","USB4105-GF-A","DigiKey","11198441","https://gct.co/files/drawings/usb4105.pdf","0.65","Power-only sink; separate CC resistors; D+/D-/SBU intentionally NC; shield to GND.")
    passive("R_CC1","5.1k 1%",(62,35),"RC0603FR-075K1L","0.005","USB-C CC1 Rd to GND.")
    passive("R_CC2","5.1k 1%",(74,35),"RC0603FR-075K1L","0.005","USB-C CC2 Rd to GND.")
    add("Device:D_TVS","D1","LESD8LH5.0CT5G",(62,55),"Diode_SMD:D_SOD-882","Leshan Radio Company","LESD8LH5.0CT5G","LCSC","C172420","https://www.lcsc.com/product-detail/C172420.html","0.0083","Bidirectional VBUS TVS; place at connector with shortest ground return.")
    passive("C_IN1","1uF 16V X7R",(76,55),"GRM188R71C105KA12D","0.08","eFuse input bulk; USB-C sink-side nominal capacitance remains below 10uF.","C")
    passive("C_IN2","100nF 50V X7R",(87,55),"GRM188R71H104KA93D","0.02","TPS259531 high-frequency input bypass.","C")
    add("dawn-dock:TPS259531","U2","TPS259531DSGR",(105,48),"Package_SON:WSON-8-1EP_2x2mm_P0.5mm_EP0.9x1.6mm_ThermalVias","Texas Instruments","TPS259531DSGR","LCSC","C2155674","https://www.ti.com/lit/ds/symlink/tps2595.pdf","0.4114","5.7V-clamp auto-retry eFuse; EN tied high; 1.53k ILM; 100nF dVdt; exposed pad to GND; thermal layout required.")
    passive("R_ILIM1","1.53k 1%",(105,70),"RC0603FR-071K53L","0.005","RILM; TI Eq.4 gives 2000/1530+0.04 = 1.347A nominal; conservative +7.5%/-1% estimate 1.463A.")
    passive("C_DVDT1","100nF 50V X7R",(92,70),"GRM188R71H104KA93D","0.02","dVdt soft-start: TI Eq.3 gives about 0.42V/ms; about 11.9ms to 5V.","C")
    passive("R_FLT1","10k 1%",(123,69),"RC0603FR-0710KL","0.005","Open-drain eFuse FLT pull-up to 3.3V.")
    passive("C_OUT1","10uF 10V X5R",(137,53),"GRM31CR61A106KA01L","0.3351","Local protected-rail ceramic bulk.","C",footprint="Capacitor_SMD:C_1206_3216Metric")
    passive("C_OUT2","100nF 50V X7R",(148,53),"GRM188R71H104KA93D","0.02","Protected-rail high-frequency bypass.","C")
    add("Device:C","C_BULK1","470uF 10V",(159,53),"Capacitor_THT:C_Radial_D8.0mm_H11.5mm_P3.50mm","Panasonic Industry","EEU-FR1A471","DigiKey","EEU-FR1A471","https://industrial.panasonic.com/cdbs/www-data/pdf/RDF0000/ABA0000C1215.pdf","0.80","Low-ESR protected-rail bulk for display/audio transients; bench-verify inrush and stability.")
    # Controller and display modules.
    add("dawn-dock:ESP32-S3-DEVKITC-1-N8R8","A1","ESP32-S3-DEVKITC-1-N8R8",(105,125),"dawn-dock:ESP32-S3-DevKitC-1_Socket","Espressif Systems","ESP32-S3-DEVKITC-1-N8R8","DigiKey","15295894","https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s3/esp32-s3-devkitc-1/user_guide_v1.1.html","13.9579","Exact N8R8 module only; footprint uses two Samtec SSW-122-01-G-S sockets; antenna end must overhang/keep out copper in PCB.")
    add("dawn-dock:Waveshare-29318","DS1","3.5in CAP TOUCH LCD",(255,62),"Connector_PinSocket_2.54mm:PinSocket_1x15_P2.54mm_Vertical","Waveshare","3.5inch Capacitive Touch LCD","Waveshare","29318","https://www.waveshare.com/wiki/3.5inch_Capacitive_Touch_LCD","18.99","15-pin interface; power at 5V and 3.3V logic; verify received connector orientation and current before PCB/fabrication.")
    passive("R_BL1","100k 1%",(236,91),"RC0603FR-07100KL","0.005","Backlight control pulldown defaults display dark during reset.")
    passive("R_SD1","100k 1%",(249,91),"RC0603FR-07100KL","0.005","microSD chip-select pull-up keeps card inactive during reset.")
    # RTC and no-charge primary-cell backup.
    add("Timer_RTC:DS3231MZ","U1","DS3231MZ+",(329,48),"Package_SO:SOIC-8_3.9x4.9mm_P1.27mm","Analog Devices / Maxim Integrated","DS3231MZ+","DigiKey","DS3231MZ+","https://www.analog.com/media/en/technical-documentation/data-sheets/ds3231m.pdf","5.50","Battery-backed RTC; VBAT connects only to primary CR2032; no charge path.")
    add("dawn-dock:Keystone-3003-CR2032","BT1","CR2032 PRIMARY",(374,48),"dawn-dock:Keystone_3003_CR2032","Panasonic Energy / Keystone Electronics","CR2032; 3003","DigiKey","31939; 227448","https://www.digikey.com/en/products/detail/panasonic-energy/CR2032/31939","1.25","NON-RECHARGEABLE primary lithium cell in Keystone 3003 retainer. DO NOT CHARGE. Verify polarity and service access.")
    passive("C_RTC1","100nF 50V X7R",(329,70),"GRM188R71H104KA93D","0.02","DS3231M VCC decoupling per pin description.","C")
    passive("R_RTC1","10k 1%",(344,70),"RC0603FR-0710KL","0.005","DS3231M INT/SQW open-drain pull-up to 3.3V.")
    # I2C breakout and optional carrier pull-ups.
    add("dawn-dock:Adafruit-4162","A3","VEML7700 BREAKOUT",(329,110),"dawn-dock:Adafruit_4162_VEML7700","Adafruit Industries","4162","Adafruit","4162","https://www.adafruit.com/product/4162","4.95","Power from 3.3V; onboard I2C pull-ups participate in aggregate bus resistance; optical placement pending.")
    for ref,net,x in [("R_I2C1","I2C_SDA",310),("R_I2C2","I2C_SCL",322)]:
        passive(ref,"4.7k 1% DNP",(x,132),"RC0603FR-074K7L","0.005","DNP by default because display/ALS modules include pull-ups; populate only after measured rise-time review.")
        dnp_refs.add(comps[ref].reference); connect(ref,"1","+3V3"); connect(ref,"2",net)
    # Audio module and off-board speaker.
    add("dawn-dock:Adafruit-3006","A2","MAX98357A I2S AMP",(255,130),"dawn-dock:Adafruit_3006_MAX98357A","Adafruit Industries","3006","Adafruit","3006","https://www.adafruit.com/product/3006","5.95","5V I2S class-D breakout; AMP_SD hardware pulldown; default gain; volume capped in firmware; no microphone path.")
    add("dawn-dock:Speaker-8R-2W","SPK1","8ohm 2W Speaker (B)",(295,130),"","Waveshare","8ohm 2W Speaker (B)","Waveshare","27859","https://www.waveshare.com/8ohm-2w-speaker-b.htm","1.99","Off-board enclosed speaker; verify cable termination, SPL, distortion, enclosure heating, and acoustic fit on bench.")
    passive("R_AMP1","100k 1%",(238,151),"RC0603FR-07100KL","0.005","AMP_SD pulldown keeps amplifier shut down through reset.")
    # Five wetted controls through exact 5V-tolerant Schmitt interface.
    add("dawn-dock:SN74LVC14APWR","U3","SN74LVC14APWR",(145,196),"Package_SO:TSSOP-14_4.4x5mm_P0.65mm","Texas Instruments","SN74LVC14APWR","LCSC","SN74LVC14APWR","https://www.ti.com/lit/ds/symlink/sn74lvc14a.pdf","0.1498","3.3V-powered Schmitt inverter; inputs tolerate 5V; five contact channels used; unused 6A tied GND.")
    passive("C_U3","100nF 50V X7R",(145,224),"GRM188R71H104KA93D","0.02","SN74LVC14A local VCC bypass.","C")
    add("Switch:SW_Push","SW1","SNOOZE",(62,186),"Button_Switch_THT:SW_TH_Tactile_Omron_B3F-10xx","Omron","B3F-1000","LCSC","B3F-1000","https://components.omron.com/us-en/products/switches/B3F","0.093","Large enclosure plunger; 5V/4.7k contact wetting; post-buffer SNOOZE_N remains active low.")
    add("Switch:SW_Push","SW2","BRIGHTNESS",(62,208),"Button_Switch_THT:SW_TH_Tactile_Omron_B3F-10xx","Omron","B3F-1000","LCSC","B3F-1000","https://components.omron.com/us-en/products/switches/B3F","0.093","Separated smaller actuator; 5V/4.7k contact wetting; post-buffer BRIGHTNESS_N active low.")
    add("dawn-dock:PEC11R-4215F-S0024","ENC1","PEC11R-4215F-S0024",(62,238),"dawn-dock:PEC11R-4xxxF-Sxxxx","Bourns","PEC11R-4215F-S0024","LCSC","PEC11R-4215F-S0024","https://www.bourns.com/docs/product-datasheets/pec11r.pdf","1.6301","24-detent/24-pulse encoder with switch; each contact uses 5V/4.7k wetting; firmware debounce required.")
    raw=[("R_CTRL1","RAW_SNOOZE",85,186),("R_CTRL2","RAW_BRIGHTNESS",85,208),("R_CTRL3","RAW_ENC_A",85,230),("R_CTRL4","RAW_ENC_B",97,230),("R_CTRL5","RAW_ENC_SW",109,230)]
    for ref,net,x,y in raw:
        passive(ref,"4.7k 1%",(x,y),"RC0603FR-074K7L","0.005","Individual 5V contact-wetting pulldown; about 1.06mA when contact closes."); connect(ref,"1",net); connect(ref,"2","GND")
    # Explicit connectivity.
    for pin in ["A4","A9","B4","B9"]: connect("J_PWR1",pin,"VBUS")
    for pin in ["A1","A12","B1","B12","S1"]: connect("J_PWR1",pin,"GND")
    connect("J_PWR1","A5","CC1"); connect("J_PWR1","B5","CC2")
    for pin in ["A6","A7","A8","B6","B7","B8"]: nc("J_PWR1",pin)
    connect("R_CC1","1","CC1"); connect("R_CC1","2","GND"); connect("R_CC2","1","CC2"); connect("R_CC2","2","GND")
    connect("D1","1","VBUS"); connect("D1","2","GND")
    for ref in ["C_IN1","C_IN2"]: connect(ref,"1","VBUS"); connect(ref,"2","GND")
    connect("U2","1","EFUSE_DVDT"); connect("U2","2","VBUS"); connect("U2","3","VBUS"); connect("U2","4","VBUS"); connect("U2","5","+5V_SYS"); connect("U2","6","EFUSE_FLT_N"); connect("U2","7","EFUSE_ILM"); connect("U2","8","GND"); connect("U2","9","GND")
    connect("C_DVDT1","1","EFUSE_DVDT"); connect("C_DVDT1","2","GND"); connect("R_ILIM1","1","EFUSE_ILM"); connect("R_ILIM1","2","GND"); connect("R_FLT1","1","+3V3"); connect("R_FLT1","2","EFUSE_FLT_N")
    for ref in ["C_OUT1","C_OUT2","C_BULK1"]: connect(ref,"1","+5V_SYS"); connect(ref,"2","GND")
    devmap={"J1-1":"+3V3","J1-2":"+3V3","J1-3":"CHIP_PU","J1-4":"ENC_A","J1-5":"ENC_B","J1-6":"LCD_BL","J1-7":"ENC_SW","J1-8":"SNOOZE_N","J1-9":"I2S_BCLK","J1-10":"I2S_LRCLK","J1-11":"I2S_DOUT","J1-12":"I2C_SDA","J1-15":"I2C_SCL","J1-16":"TFT_CS","J1-17":"TFT_MOSI","J1-18":"TFT_SCLK","J1-19":"TFT_MISO","J1-20":"TFT_DC","J1-21":"+5V_SYS","J1-22":"GND","J3-1":"GND","J3-2":"U0TXD","J3-3":"U0RXD","J3-5":"RTC_INT_N","J3-6":"TP_RST","J3-7":"BRIGHTNESS_N","J3-8":"AMP_SD","J3-9":"SD_CS","J3-17":"TP_INT","J3-18":"TFT_RST","J3-21":"GND","J3-22":"GND","J3-14":"BOOT_GPIO0"}
    for pin,net in devmap.items(): connect("A1",pin,net)
    for pin in ["J1-13","J1-14","J3-4","J3-10","J3-11","J3-12","J3-13","J3-15","J3-16","J3-19","J3-20"]: nc("A1",pin)
    dispmap={"1":"+5V_SYS","2":"GND","3":"TFT_MISO","4":"TFT_MOSI","5":"TFT_SCLK","6":"TFT_CS","7":"TFT_DC","8":"TFT_RST","9":"LCD_BL","10":"I2C_SDA","11":"I2C_SCL","12":"TP_INT","13":"TP_RST","14":"SD_CS"}
    for pin,net in dispmap.items(): connect("DS1",pin,net)
    nc("DS1","15"); connect("R_BL1","1","LCD_BL"); connect("R_BL1","2","GND"); connect("R_SD1","1","+3V3"); connect("R_SD1","2","SD_CS")
    nc("U1","1"); connect("U1","2","+3V3"); connect("U1","3","RTC_INT_N"); nc("U1","4"); connect("U1","5","GND"); connect("U1","6","VBAT_RTC"); connect("U1","7","I2C_SDA"); connect("U1","8","I2C_SCL")
    connect("BT1","1","VBAT_RTC"); connect("BT1","2","GND"); connect("C_RTC1","1","+3V3"); connect("C_RTC1","2","GND"); connect("R_RTC1","1","+3V3"); connect("R_RTC1","2","RTC_INT_N")
    connect("A3","1","+3V3"); connect("A3","2","GND"); nc("A3","3"); connect("A3","4","I2C_SCL"); connect("A3","5","I2C_SDA")
    ampmap={"1":"+5V_SYS","2":"GND","3":"I2S_BCLK","4":"I2S_LRCLK","5":"I2S_DOUT","7":"AMP_SD","8":"SPK+","9":"SPK-"}
    for pin,net in ampmap.items(): connect("A2",pin,net)
    nc("A2","6"); connect("SPK1","1","SPK+"); connect("SPK1","2","SPK-"); connect("R_AMP1","1","AMP_SD"); connect("R_AMP1","2","GND")
    # Control contacts: one side to +5V; raw node through pulldown into LVC14.
    connect("SW1","1","+5V_SYS"); connect("SW1","2","RAW_SNOOZE"); connect("SW2","1","+5V_SYS"); connect("SW2","2","RAW_BRIGHTNESS")
    connect("ENC1","A","RAW_ENC_A"); connect("ENC1","C","+5V_SYS"); connect("ENC1","B","RAW_ENC_B"); connect("ENC1","1","+5V_SYS"); connect("ENC1","2","RAW_ENC_SW")
    u3map={"1":"RAW_ENC_A","2":"ENC_A","3":"RAW_ENC_B","4":"ENC_B","5":"RAW_ENC_SW","6":"ENC_SW","9":"RAW_SNOOZE","8":"SNOOZE_N","11":"RAW_BRIGHTNESS","10":"BRIGHTNESS_N","13":"GND","14":"+3V3"}
    for pin,net in u3map.items(): connect("U3",pin,net)
    nc("U3","12"); connect("U3","7","GND"); connect("C_U3","1","+3V3"); connect("C_U3","2","GND")
    # ERC source declarations.
    for idx,(net,pos) in enumerate([("VBUS",(82,78)),("+3V3",(104,78)),("VBAT_RTC",(126,78)),("GND",(148,78))],1):
        ref=f"#FLG0{idx}"; add("power:PWR_FLAG",ref,"PWR_FLAG",pos,"","N/A","PCB_NET_FLAG","N/A","N/A","~","0","ERC-only source declaration; not a physical BOM item.",in_bom=False); connect(ref,"1",net)
    # Named test access required by ELEC-10 and the issue acceptance criteria.
    testnets=["VBUS","+5V_SYS","+3V3","GND","CHIP_PU","BOOT_GPIO0","I2C_SDA","I2C_SCL","RTC_INT_N","LCD_BL","TFT_SCLK","TFT_MOSI","TFT_MISO","TFT_CS","TFT_DC","TFT_RST","I2S_BCLK","I2S_LRCLK","I2S_DOUT","AMP_SD","SPK+","SPK-","ENC_A","ENC_B","ENC_SW","SNOOZE_N","BRIGHTNESS_N","U0TXD","U0RXD","EFUSE_FLT_N"]
    for i,net in enumerate(testnets,1):
        ref=f"TP{i}"; add("Connector:TestPoint",ref,net,(28+(i-1)%10*37,258+(i-1)//10*12),"TestPoint:TestPoint_Pad_D1.5mm","N/A","PCB_TEST_PAD","N/A","N/A","~","0","Unpopulated labeled PCB test pad; probe limits follow connected rail/signal.",in_bom=False); connect(ref,"1",net)
    for i,pos in enumerate([(365,180),(385,180),(365,205),(385,205)],1):
        add("Mechanical:MountingHole",f"H{i}","M3 mounting hole",pos,"MountingHole:MountingHole_3.2mm_M3","N/A","PCB_M3_HOLE","N/A","N/A","~","0","Carrier mounting feature; final positions deferred to measured enclosure/PCB issue #4.",in_bom=False)
    sch.add_text("USB-C 5V SELV INPUT / TVS / EFUSE",(20,18),size=1.8,bold=True)
    sch.add_text("CONTROLLER + DISPLAY",(75,88),size=1.8,bold=True)
    sch.add_text("RTC / PRIMARY CR2032 — DO NOT CHARGE",(302,18),size=1.8,bold=True)
    sch.add_text("AUDIO + AMBIENT SENSOR",(225,103),size=1.8,bold=True)
    sch.add_text("5V-WETTED CONTROLS / 3V3 SCHMITT BUFFER",(35,165),size=1.8,bold=True)
    sch.add_text("All evidence on this sheet is static schematic analysis. PCB, fabrication, assembly, EMC, thermal, and bench validation remain pending.",(20,288),size=1.0,bold=True)
    issues=sch.validate(); errors=[x for x in issues if getattr(x,"severity","")=="error"]
    if errors: raise SystemExit("Schematic API validation failed: "+"; ".join(map(str,errors)))
    out=Path(args.output); out.parent.mkdir(parents=True,exist_ok=True); sch.save_as(out)
    # kicad-sch-api 0.5.6 reads but does not model KiCad's per-symbol DNP flag.
    # Mark the explicitly tracked references in the generated S-expression.
    text=out.read_text(encoding="utf-8")
    for ref in sorted(dnp_refs):
        marker=f'\n\t\t(property "Reference" "{ref}"'
        ref_at=text.find(marker)
        if ref_at < 0: raise SystemExit(f"Cannot locate DNP reference {ref}")
        start=text.rfind("\n\t(symbol\n",0,ref_at)
        end=text.find("\n\t(symbol\n",ref_at)
        if end < 0: end=len(text)
        block=text[start:end]
        if "\n\t\t(dnp no)" not in block: raise SystemExit(f"Cannot locate DNP flag for {ref}")
        block=block.replace("\n\t\t(dnp no)","\n\t\t(dnp yes)",1)
        text=text[:start]+block+text[end:]
    out.write_text(text,encoding="utf-8")
    print(f"generated {out} with {len(comps)} symbols; validation issues={len(issues)} errors=0")
    return 0

if __name__=="__main__": raise SystemExit(main())
