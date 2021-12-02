//
//  MapView.swift
//  Attnd
//
//  Created by Andrew Beers on 11/29/21.
//

import SwiftUI
import MapKit


struct MapView: View {
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 32.75548830000000000000, longitude: -97.33076580000000000000), span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))
    @State var locationManager = LocationManager()
    
    var body: some View {
        Map(coordinateRegion: $region, annotationItems: locationManager.locations) { location in
            MapAnnotation(coordinate: CLLocationCoordinate2D(latitude: Double(location.latitude)!, longitude: Double(location.longitude)!),
                          content: {
                Image(systemName: "gearshape")
            })
        }
    }
}

struct MapView_Previews: PreviewProvider {
    static var previews: some View {
        MapView()
    }
}
