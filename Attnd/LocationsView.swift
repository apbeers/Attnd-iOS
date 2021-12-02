//
//  LocationsView.swift
//  Attnd
//
//  Created by Andrew Beers on 11/29/21.
//

import SwiftUI
import Foundation


struct Location: Decodable, Identifiable {
    let id: Int
    let name: String
    let snippet: String
    let description: String
    let website: String?
    let latitude: String
    let longitude: String
    let address: String
    let user: Int
    let event: Int
    let image: String
}


class LocationManager: ObservableObject {
    @Published var locations = [Location]()
    
    init() {
        guard let url = URL(string: "https://attnd-web-test.herokuapp.com/events/1/locations/") else {
            return
        }
        
        URLSession.shared.dataTask(with: url) {(data, respose, error) in
            
            guard let data = data else { return }
            
            DispatchQueue.main.async {
                self.locations = try! JSONDecoder().decode([Location].self, from: data)
            }
        }.resume()
    }
}

struct LocationsView: View {
    @State var locationManager = LocationManager()
    var body: some View {
        List(locationManager.locations) { location in
            HStack {
                AsyncImage(urlString: location.image)
                    .frame(width: 100, height: 100)
                VStack(alignment: .leading) {
                    Text(location.name)
                    Text(location.snippet)
                }
            }
        }
    }
}


struct LocationsView_Previews: PreviewProvider {
    static var previews: some View {
        LocationsView()
    }
}
