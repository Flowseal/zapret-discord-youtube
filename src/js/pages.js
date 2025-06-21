/**
 * Simulate app routing using pagination
 * 
 * - Get all elements from container
 * - Set first to visible
 * - Create change visibility function
 * 
*/
// get elements from container
var container = document.getElementById("pages")
var items = container.children
var pages = [null]
var page = 1

// Add 'page' class to all elements inside 'pages' container
for(var i = 0; i < items.length; i++){
    if(items[i]){
        items[i].className = [items[i].className, "page"].join(" ")
        pages.push(items[i])
    }
}

// Set first page to visible
if(pages[page]) pages[page].style.display = "block" 

// Function used to set visibility, called from 'gui.hta' file
function setPage(p){
    var curr = pages[p]
    var prev = pages[page]

    if(curr){
        prev.style.display = "none"; 
        curr.style.display = "block";
        page = p
    }
}

