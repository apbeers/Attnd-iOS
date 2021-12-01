//
//  Helpers.swift
//  Attnd
//
//  Created by Andrew Beers on 11/30/21.
//

import Foundation
import SwiftUI


struct Event: Decodable, Identifiable {
    let id: Int
    let locations: [Location]
    let notifications: [Notification]
    let flyer: String
    let name: String
    let event_code: String
    let description: String
    let latitude: String
    let longitude: String
    let start_time: String
    let paid: Bool
    let address: String
}

class EventManager: ObservableObject {
    @Published var events = [Event]()
    
    init() {
        guard let url = URL(string: "https://attnd-web-test.herokuapp.com/events/1/") else {
            return
        }
        
        URLSession.shared.dataTask(with: url) {(data, _, _) in
            guard let data = data else {
                return
            }
            
            let events = try! JSONDecoder().decode([Event].self, from: data)
            self.events = events
        }.resume()
    }
}


class ImageLoaderService: ObservableObject {
    @Published var image: UIImage = UIImage()
    
    func loadImage(for urlString: String) {
        guard let url = URL(string: urlString) else { return }
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data else { return }
            DispatchQueue.main.async {
                self.image = UIImage(data: data) ?? UIImage()
            }
        }
        task.resume()
    }
    
}
