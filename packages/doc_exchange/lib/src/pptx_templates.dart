import 'pptx_common.dart';

/// Feste Bestandteile einer minimalen, gültigen PowerPoint-Datei.
/// Ein leerer Folienmaster, ein leeres Layout, ein schlichtes Design.

String relsXml(List<String> relationships) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<Relationships xmlns="$nsRel">${relationships.join()}</Relationships>';

const _emptyTree = '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';

const _ns = 'xmlns:a="$nsA" xmlns:r="$nsR" xmlns:p="$nsP"';

String slideXml(String shapes) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<p:sld $_ns><p:cSld><p:spTree>$_emptyTree$shapes</p:spTree></p:cSld>'
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>';

/// Alle Teile ausser den Folien und Bildern.
Map<String, String> packageParts({
  required int slideCount,
  required Set<String> mediaExtensions,
  double slideWidthMm = 210,
  double slideHeightMm = 297,
}) {
  final slideOverrides = [
    for (var i = 1; i <= slideCount; i++)
      '<Override PartName="/ppt/slides/slide$i.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>',
  ].join();
  final mediaDefaults = [
    if (mediaExtensions.contains('jpeg')) '<Default Extension="jpeg" ContentType="image/jpeg"/>',
    if (mediaExtensions.contains('png')) '<Default Extension="png" ContentType="image/png"/>',
  ].join();
  final slideIds = [for (var i = 1; i <= slideCount; i++) '<p:sldId id="${255 + i}" r:id="rId${10 + i}"/>'].join();
  final slideRels = [
    for (var i = 1; i <= slideCount; i++)
      '<Relationship Id="rId${10 + i}" Type="$relBase/slide" Target="slides/slide$i.xml"/>',
  ];

  return {
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>$mediaDefaults'
        '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
        '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
        '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
        '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'
        '<Override PartName="/ppt/presProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"/>'
        '<Override PartName="/ppt/viewProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"/>'
        '<Override PartName="/ppt/tableStyles.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"/>'
        '$slideOverrides'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
        '</Types>',
    '_rels/.rels': relsXml([
      '<Relationship Id="rId1" Type="$relBase/officeDocument" Target="ppt/presentation.xml"/>',
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>',
      '<Relationship Id="rId3" Type="$relBase/extended-properties" Target="docProps/app.xml"/>',
    ]),
    'docProps/core.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>Textly-Dokument</dc:title></cp:coreProperties>',
    'docProps/app.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
        '<Application>Textly</Application><Slides>$slideCount</Slides></Properties>',
    'ppt/presentation.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<p:presentation $_ns saveSubsetFonts="1">'
        '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
        '<p:sldIdLst>$slideIds</p:sldIdLst>'
        // A4 hoch (210 × 297 mm) oder quer (297 × 210 mm)
        '<p:sldSz cx="${emu(slideWidthMm)}" cy="${emu(slideHeightMm)}"/><p:notesSz cx="6858000" cy="9144000"/>'
        '</p:presentation>',
    'ppt/_rels/presentation.xml.rels': relsXml([
      '<Relationship Id="rId1" Type="$relBase/slideMaster" Target="slideMasters/slideMaster1.xml"/>',
      '<Relationship Id="rId2" Type="$relBase/theme" Target="theme/theme1.xml"/>',
      '<Relationship Id="rId3" Type="$relBase/presProps" Target="presProps.xml"/>',
      '<Relationship Id="rId4" Type="$relBase/viewProps" Target="viewProps.xml"/>',
      '<Relationship Id="rId5" Type="$relBase/tableStyles" Target="tableStyles.xml"/>',
      ...slideRels,
    ]),
    'ppt/presProps.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<p:presentationPr $_ns/>',
    'ppt/viewProps.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<p:viewPr $_ns/>',
    'ppt/tableStyles.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<a:tblStyleLst xmlns:a="$nsA" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>',
    'ppt/slideMasters/slideMaster1.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<p:sldMaster $_ns><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>'
        '<p:spTree>$_emptyTree</p:spTree></p:cSld>'
        '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" '
        'accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
        '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>'
        '<p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="2600"/></a:lvl1pPr></p:titleStyle>'
        '<p:bodyStyle><a:lvl1pPr><a:defRPr sz="1050"/></a:lvl1pPr></p:bodyStyle>'
        '<p:otherStyle><a:lvl1pPr><a:defRPr sz="1050"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>',
    'ppt/slideMasters/_rels/slideMaster1.xml.rels': relsXml([
      '<Relationship Id="rId1" Type="$relBase/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>',
      '<Relationship Id="rId2" Type="$relBase/theme" Target="../theme/theme1.xml"/>',
    ]),
    'ppt/slideLayouts/slideLayout1.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<p:sldLayout $_ns type="blank" preserve="1"><p:cSld name="Leer"><p:spTree>$_emptyTree</p:spTree></p:cSld>'
        '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>',
    'ppt/slideLayouts/_rels/slideLayout1.xml.rels': relsXml([
      '<Relationship Id="rId1" Type="$relBase/slideMaster" Target="../slideMasters/slideMaster1.xml"/>',
    ]),
    'ppt/theme/theme1.xml': _theme,
  };
}

const _theme = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<a:theme xmlns:a="$nsA" name="Textly"><a:themeElements>'
    '<a:clrScheme name="Textly">'
    '<a:dk1><a:srgbClr val="1D2733"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>'
    '<a:dk2><a:srgbClr val="5B6773"/></a:dk2><a:lt2><a:srgbClr val="E8EEF7"/></a:lt2>'
    '<a:accent1><a:srgbClr val="2F5BD3"/></a:accent1><a:accent2><a:srgbClr val="1F7A5A"/></a:accent2>'
    '<a:accent3><a:srgbClr val="B4442C"/></a:accent3><a:accent4><a:srgbClr val="C98A12"/></a:accent4>'
    '<a:accent5><a:srgbClr val="5B6773"/></a:accent5><a:accent6><a:srgbClr val="1D2733"/></a:accent6>'
    '<a:hlink><a:srgbClr val="2F5BD3"/></a:hlink><a:folHlink><a:srgbClr val="5B6773"/></a:folHlink></a:clrScheme>'
    '<a:fontScheme name="Textly"><a:majorFont><a:latin typeface="Roboto Condensed"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
    '<a:minorFont><a:latin typeface="Roboto"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>'
    '<a:fmtScheme name="Textly">'
    '<a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>'
    '<a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>'
    '<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>'
    '<a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>'
    '</a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>';
