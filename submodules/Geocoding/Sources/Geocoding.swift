import Foundation
import Contacts
import CoreLocation
import MapKit
import SwiftSignalKit

public func geocodeLocation(address: String, locale: Locale? = nil) -> Signal<[CLPlacemark]?, NoError> {
    return Signal { subscriber in
        if #available(iOS 26.0, *) {
            guard let request = MKGeocodingRequest(addressString: address) else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            request.preferredLocale = locale
            request.getMapItems(completionHandler: { mapItems, _ in
                // CLPlacemark is still the public result type of this module. MapKit
                // keeps the compatibility object available while its properties are
                // replaced by MKMapItem's address APIs on iOS 26.
                subscriber.putNext(mapItems?.compactMap { legacyPlacemark(for: $0) })
                subscriber.putCompletion()
            })
            return ActionDisposable {
                request.cancel()
            }
        }

        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(address, in: nil, preferredLocale: locale) { placemarks, _ in
            subscriber.putNext(placemarks)
            subscriber.putCompletion()
        }
        return ActionDisposable {
            geocoder.cancelGeocode()
        }
    }
}

public func geocodeLocation(address: CNPostalAddress, locale: Locale? = nil) -> Signal<(Double, Double)?, NoError> {
    return Signal { subscriber in
        if #available(iOS 26.0, *) {
            let addressString = CNPostalAddressFormatter.string(from: address, style: .mailingAddress)
            guard let request = MKGeocodingRequest(addressString: addressString) else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            request.preferredLocale = locale
            request.getMapItems(completionHandler: { mapItems, _ in
                if let location = mapItems?.first?.location {
                    subscriber.putNext((location.coordinate.latitude, location.coordinate.longitude))
                } else {
                    subscriber.putNext(nil)
                }
                subscriber.putCompletion()
            })
            return ActionDisposable {
                request.cancel()
            }
        }

        let geocoder = CLGeocoder()
        geocoder.geocodePostalAddress(address, preferredLocale: locale) { placemarks, _ in
            if let location = placemarks?.first?.location {
                subscriber.putNext((location.coordinate.latitude, location.coordinate.longitude))
            } else {
                subscriber.putNext(nil)
            }
            subscriber.putCompletion()
        }
        return ActionDisposable {
            geocoder.cancelGeocode()
        }
    }
}

public struct ReverseGeocodedPlacemark {
    public let name: String?
    public let street: String?
    public let city: String?
    public let state: String?
    public let country: String?
    public let countryCode: String?
    
    public var compactDisplayAddress: String? {
        if let street = self.street {
            return street
        }
        if let city = self.city {
            return city
        }
        if let country = self.country {
            return country
        }
        return nil
    }
    
    public var fullAddress: String {
        var components: [String] = []
        if let street = self.street {
            components.append(street)
        }
        if let city = self.city {
            components.append(city)
        }
        if let country = self.country {
            components.append(country)
        }
        
        return components.joined(separator: ", ")
    }
}

public func reverseGeocodeLocation(latitude: Double, longitude: Double, locale: Locale? = nil) -> Signal<ReverseGeocodedPlacemark?, NoError> {
    return Signal { subscriber in
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            request.preferredLocale = locale
            request.getMapItems(completionHandler: { mapItems, _ in
                if let mapItem = mapItems?.first {
                    subscriber.putNext(reverseGeocodedPlacemark(from: mapItem))
                } else {
                    subscriber.putNext(nil)
                }
                subscriber.putCompletion()
            })
            return ActionDisposable {
                request.cancel()
            }
        }

        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude), preferredLocale: locale, completionHandler: { placemarks, _ in
            if let placemarks, let placemark = placemarks.first {
                subscriber.putNext(reverseGeocodedPlacemark(from: placemark))
                subscriber.putCompletion()
            } else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
            }
        })
        return ActionDisposable {
            geocoder.cancelGeocode()
        }
    }
}

private func reverseGeocodedPlacemark(from placemark: CLPlacemark) -> ReverseGeocodedPlacemark {
    let countryName = placemark.country
    let countryCode = placemark.isoCountryCode
    if placemark.thoroughfare == nil && placemark.locality == nil && placemark.country == nil {
        return ReverseGeocodedPlacemark(name: placemark.name, street: placemark.name, city: nil, state: nil, country: nil, countryCode: nil)
    }
    if placemark.thoroughfare == nil && placemark.locality == nil, let ocean = placemark.ocean {
        return ReverseGeocodedPlacemark(name: ocean, street: nil, city: nil, state: nil, country: countryName, countryCode: countryCode)
    }
    return ReverseGeocodedPlacemark(name: nil, street: placemark.thoroughfare, city: placemark.locality, state: placemark.administrativeArea, country: countryName, countryCode: countryCode)
}

@available(iOS 26.0, *)
private func legacyPlacemark(for mapItem: MKMapItem) -> CLPlacemark? {
    // The compatibility property is intentionally accessed dynamically so the
    // iOS 26 SDK does not turn this iOS 17-compatible result bridge into an error.
    return mapItem.value(forKey: "placemark") as? CLPlacemark
}

@available(iOS 26.0, *)
private func reverseGeocodedPlacemark(from mapItem: MKMapItem) -> ReverseGeocodedPlacemark {
    let address = mapItem.address
    let representations = mapItem.addressRepresentations
    let street = address?.shortAddress ?? address?.fullAddress
    let city = representations?.cityName
    let country = representations?.regionName

    if street == nil && city == nil && country == nil {
        return ReverseGeocodedPlacemark(name: mapItem.name, street: mapItem.name, city: nil, state: nil, country: nil, countryCode: nil)
    }
    return ReverseGeocodedPlacemark(name: mapItem.name, street: street, city: city, state: nil, country: country, countryCode: nil)
}

let customAbbreviations = ["AE": "UAE", "GB": "UK", "US": "USA"]
public func displayCountryName(_ countryCode: String, locale: Locale?) -> String {
    let locale = locale ?? Locale.current
    if locale.identifier.lowercased().contains("en"), let shortName = customAbbreviations[countryCode] {
        return shortName
    } else {
        return locale.localizedString(forRegionCode: countryCode) ?? countryCode
    }
}
