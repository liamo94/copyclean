//
//  Theme.swift
//  Pods
//
//  Created by Illanes, J.P. on 4/24/16.
//
//

import Foundation

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    import UIKit
    /// Typealias for UIColor
    public typealias RPColor = UIColor
    /// Typealias for UIFont
    public typealias RPFont = UIFont
#else
    import AppKit
    /// Typealias for NSColor
    public typealias RPColor = NSColor
    /// Typealias for NSFont
    public typealias RPFont = NSFont

#endif

private typealias RPThemeDict = [String: [AnyHashable: AnyObject]]
private typealias RPThemeStringDict = [String:[String:String]]

/// Theme parser, can be used to configure the theme parameters. 
open class Theme {
    internal let theme : String
    internal var lightTheme : String!
    
    /// Regular font to be used by this theme
    open var codeFont : RPFont!
    /// Bold font to be used by this theme
    open var boldCodeFont : RPFont!
    /// Italic font to be used by this theme
    open var italicCodeFont : RPFont!
    
    private var themeDict : RPThemeDict!
    private var strippedTheme : RPThemeStringDict!
    
    /// Default background color for the current theme.
    open var themeBackgroundColor : RPColor!
    
    /**
     Initialize the theme with the given theme name.
     
     - parameter themeString: Theme to use.
     */
    init(themeString: String)
    {
        theme = themeString
        setCodeFont(RPFont(name: "Courier", size: 14)!)
        strippedTheme = stripTheme(themeString)
        lightTheme = strippedThemeToString(strippedTheme)
        themeDict = strippedThemeToTheme(strippedTheme)
        var bkgColorHex = strippedTheme[".hljs"]?["background"]
        if(bkgColorHex == nil)
        {
            bkgColorHex = strippedTheme[".hljs"]?["background-color"]
        }
        if let bkgColorHex = bkgColorHex
        {
            // A named colour (far's `navy`) has no `#`; force-unwrapping the range crashed on it.
            if let range = bkgColorHex.range(of: "#")
            {
                themeBackgroundColor = colorWithHexString(String(bkgColorHex[range.lowerBound...]))
            }else
            {
                themeBackgroundColor = colorWithHexString(bkgColorHex)
            }
        }else
        {
            themeBackgroundColor = RPColor.white
        }
    }
    
    /**
     Changes the theme font. This will try to automatically populate the codeFont, boldCodeFont and italicCodeFont properties based on the provided font.
     
     - parameter font: UIFont (iOS or tvOS) or NSFont (OSX)
     */
    open func setCodeFont(_ font: RPFont)
    {
        codeFont = font
        
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let boldDescriptor = UIFontDescriptor(fontAttributes: [UIFontDescriptor.AttributeName.family:font.familyName,
                                                                UIFontDescriptor.AttributeName.face:"Bold"])
        let italicDescriptor = UIFontDescriptor(fontAttributes: [UIFontDescriptor.AttributeName.family:font.familyName,
                                                                 UIFontDescriptor.AttributeName.face:"Italic"])
        let obliqueDescriptor = UIFontDescriptor(fontAttributes: [UIFontDescriptor.AttributeName.family:font.familyName,
                                                                  UIFontDescriptor.AttributeName.face:"Oblique"])
        #else
        let boldDescriptor = NSFontDescriptor(fontAttributes: [.family:font.familyName!,
                                                                   .face:"Bold"])
        let italicDescriptor = NSFontDescriptor(fontAttributes: [.family:font.familyName!,
                                                                     .face:"Italic"])
        let obliqueDescriptor = NSFontDescriptor(fontAttributes: [.family:font.familyName!,
                                                                      .face:"Oblique"])
        #endif
        
        boldCodeFont = RPFont(descriptor: boldDescriptor, size: font.pointSize)
        italicCodeFont = RPFont(descriptor: italicDescriptor, size: font.pointSize)
        
        if(italicCodeFont == nil || italicCodeFont.familyName != font.familyName)
        {
            italicCodeFont = RPFont(descriptor: obliqueDescriptor, size: font.pointSize)
        }
        if(italicCodeFont == nil)
        {
            italicCodeFont = font
        }
        
        if(boldCodeFont == nil)
        {
            boldCodeFont = font
        }

        if(themeDict != nil)
        {
            themeDict = strippedThemeToTheme(strippedTheme)
        }
    }
    
    internal func applyStyleToString(_ string: String, styleList: [String]) -> NSAttributedString
    {
        let returnString : NSAttributedString
        
        if styleList.count > 0
        {
            var attrs = [AttributedStringKey: Any]()
            attrs[.font] = codeFont
            // highlight.js 11 puts several classes on one span ("hljs-title function_"): style
            // each, then the compound selector (.hljs-title.function_), which wins.
            var keys = [String]()
            for style in styleList
            {
                let classes = style.split(separator: " ").map(String.init)
                keys += classes
                if classes.count > 1 { keys.append(classes.joined()) }
            }
            for key in keys
            {
                var style = key

                if keys.contains("hljs-title") && keys.contains("hljs-function") && themeDict["hljs-function-hljs-title"] != nil {
                    style = "hljs-function-hljs-title"
                }

                if keys.contains("hljs-title") && keys.contains("hljs-class") && themeDict["hljs-class-hljs-title"] != nil {
                    style = "hljs-class-hljs-title"
                }

                if let themeStyle = themeDict[style] as? [AttributedStringKey: Any]
                {
                    for (attrName, attrValue) in themeStyle
                    {
                        attrs.updateValue(attrValue, forKey: attrName)
                    }
                }
            }
            
            returnString = NSAttributedString(string: string, attributes:attrs )
        }
        else
        {
			returnString = NSAttributedString(string: string, attributes:[AttributedStringKey.font:codeFont as Any] )
        }

        return returnString
    }
    
    private func stripTheme(_ themeString : String) -> [String:[String:String]]
    {
        let themeString = Theme.removingMediaBlocks(themeString)
        let objcString = (themeString as NSString)
        // Selectors may be compound (.hljs-title.class_); their dots are dropped from the key
        // later, matching the joined classes `applyStyleToString` looks up.
        let selector = "\\.[a-zA-Z0-9\\-_]*(?:\\.[a-zA-Z0-9\\-_]+)*"
        let cssRegex = try! NSRegularExpression(pattern: "(?:(\(selector)(?:[, ]\(selector))*)\\{([^\\}]*?)\\})", options:[.caseInsensitive])
        
        let results = cssRegex.matches(in: themeString,
                                               options: [.reportCompletion],
                                               range: NSMakeRange(0, objcString.length))
        
        var resultDict = [String:[String:String]]()
        
        for result in results {
            if(result.numberOfRanges == 3)
            {
                var attributes = [String:String]()
                let cssPairs = objcString.substring(with: result.range(at: 2)).components(separatedBy: ";")
                for pair in cssPairs {
                    let cssPropComp = pair.components(separatedBy: ":")
                    // `inherit` would parse as gray, and could overwrite the class's real colour.
                    if(cssPropComp.count == 2 && cssPropComp[1] != "inherit")
                    {
                        attributes[cssPropComp[0]] = cssPropComp[1]
                    }

                }
                if attributes.count > 0
                {
                    resultDict[objcString.substring(with: result.range(at: 1))] = attributes
                }
                
            }
            
        }
        
        var returnDict = [String:[String:String]]()
        
        for (keys,result) in resultDict
        {
            // Only the descendant selector itself becomes the combined key — not every
            // selector it's listed with (that took .hljs-built_in's colour, among others).
            let keyArray = keys.components(separatedBy: ",").flatMap { selector -> [String] in
                let selector = selector.trimmingCharacters(in: .whitespaces)
                switch selector {
                case ".hljs-function .hljs-title": return ["hljs-function-hljs-title"]
                case ".hljs-class .hljs-title": return ["hljs-class-hljs-title"]
                default: return selector.components(separatedBy: " ")
                }
            }
            for key in keyArray {
                var props : [String:String]?
                props = returnDict[key]
                if props == nil {
                    props = [String:String]()
                }
                
                for (pName, pValue) in result
                {
                    props!.updateValue(pValue, forKey: pName)
                }
                returnDict[key] = props!
            }
        }
        
        return returnDict
    }
    
    private func strippedThemeToString(_ theme: RPThemeStringDict) -> String
    {
        var resultString = ""
        for (key, props) in theme {
            resultString += key+"{"
            for (cssProp, val) in props
            {
                if(key != ".hljs" || (cssProp.lowercased() != "background-color" && cssProp.lowercased() != "background"))
                {
                    resultString += "\(cssProp):\(val);"
                }
            }
            resultString+="}"
        }
        return resultString
    }
    
    private func strippedThemeToTheme(_ theme: RPThemeStringDict) -> RPThemeDict
    {
        var returnTheme = RPThemeDict()
        for (className, props) in theme
        {
            var keyProps = [AttributedStringKey: AnyObject]()
            for (key, prop) in props
            {
                switch key
                {
                case "color":
                    keyProps[attributeForCSSKey(key)] = colorWithHexString(prop)
                    break
                case "font-style":
                    keyProps[attributeForCSSKey(key)] = fontForCSSStyle(prop)
                    break
                case "font-weight":
                    keyProps[attributeForCSSKey(key)] = fontForCSSStyle(prop)
                    break
                case "background-color":
                    keyProps[attributeForCSSKey(key)] = colorWithHexString(prop)
                    break
                default:
                    break
                }
            }
            if keyProps.count > 0
            {
                let key = className.replacingOccurrences(of: ".", with: "")
                returnTheme[key] = keyProps
            }
        }
        return returnTheme
    }
    
    private func fontForCSSStyle(_ fontStyle:String) -> RPFont
    {
        switch fontStyle
        {
            case "bold", "bolder", "600", "700", "800", "900":
                return boldCodeFont
            case "italic", "oblique":
                return italicCodeFont
            default:
                return codeFont
        }
    }
    
    private func attributeForCSSKey(_ key: String) -> AttributedStringKey
    {
        switch key {
        case "color":
            return .foregroundColor
        case "font-weight":
            return .font
        case "font-style":
            return .font
        case "background-color":
            return .backgroundColor
        default:
            return .font
        }
    }
    
    private func colorWithHexString (_ hex:String) -> RPColor
    {

        var cString:String = hex.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if (cString.hasPrefix("#"))
        {
            cString = (cString as NSString).substring(from: 1)
        }
        else if let named = Theme.namedColors[cString.lowercased()]
        {
            cString = named
        }
        else if let rgb = Theme.colorWithRGBFunction(cString)
        {
            return rgb
        }
        else
        {
            return RPColor.gray
        }

        // #rgba / #rrggbbaa: split the alpha off.
        var alpha: CGFloat = 1
        if (cString.count == 8 || cString.count == 4)
        {
            let alphaString = (cString as NSString).substring(from: cString.count * 3 / 4)
            var a: UInt64 = 0
            Scanner(string: alphaString).scanHexInt64(&a)
            alpha = CGFloat(a) / (cString.count == 8 ? 255.0 : 15.0)
            cString = (cString as NSString).substring(to: cString.count * 3 / 4)
        }

        if (cString.count != 6 && cString.count != 3 )
        {
            return RPColor.gray
        }
        
        
        var r:UInt64 = 0, g:UInt64 = 0, b:UInt64 = 0;
        var divisor : CGFloat
        
        if (cString.count == 6 )
        {
        
            let rString = (cString as NSString).substring(to: 2)
            let gString = ((cString as NSString).substring(from: 2) as NSString).substring(to: 2)
            let bString = ((cString as NSString).substring(from: 4) as NSString).substring(to: 2)
            
            Scanner(string: rString).scanHexInt64(&r)
            Scanner(string: gString).scanHexInt64(&g)
            Scanner(string: bString).scanHexInt64(&b)
            
            divisor = 255.0
            
        }else
        {
            let rString = (cString as NSString).substring(to: 1)
            let gString = ((cString as NSString).substring(from: 1) as NSString).substring(to: 1)
            let bString = ((cString as NSString).substring(from: 2) as NSString).substring(to: 1)
            
            Scanner(string: rString).scanHexInt64(&r)
            Scanner(string: gString).scanHexInt64(&g)
            Scanner(string: bString).scanHexInt64(&b)
            
            divisor = 15.0
        }
        
        return RPColor(red: CGFloat(r) / divisor, green: CGFloat(g) / divisor, blue: CGFloat(b) / divisor, alpha: alpha)

    }

    /// `rgb(r,g,b)` / `rgba(r,g,b,a)`, as arduino-light uses.
    private static func colorWithRGBFunction(_ css: String) -> RPColor?
    {
        guard css.hasPrefix("rgb"), let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return nil }
        let parts = css[css.index(after: open)..<close].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        return RPColor(red: CGFloat(parts[0] / 255), green: CGFloat(parts[1] / 255), blue: CGFloat(parts[2] / 255),
                       alpha: CGFloat(parts.count == 4 ? parts[3] : 1))
    }

    /// The CSS colour names the bundled themes use, so they don't all fall back to gray.
    private static let namedColors: [String: String] = [
        "white": "ffffff", "black": "000000", "red": "ff0000", "green": "008000", "blue": "0000ff",
        "gray": "808080", "grey": "808080", "silver": "c0c0c0", "navy": "000080", "teal": "008080",
        "olive": "808000", "maroon": "800000", "purple": "800080", "orange": "ffa500", "gold": "ffd700",
    ]

    /// Removes `@media` blocks. The rule regex in `stripTheme` would otherwise read the rules
    /// inside them as top-level ones — the a11y themes' Windows high-contrast block
    /// (`color:highlight`) turned their strings, numbers and comments gray.
    private static func removingMediaBlocks(_ css: String) -> String
    {
        let mediaRegex = try! NSRegularExpression(pattern: "@media[^{]*\\{(?:[^{}]*\\{[^{}]*\\})*[^{}]*\\}")
        return mediaRegex.stringByReplacingMatches(in: css, range: NSMakeRange(0, (css as NSString).length), withTemplate: "")
    }
    

}
