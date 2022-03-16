using System;
using System.ComponentModel.DataAnnotations;

namespace Entities
{
    public class CategoryEntity{
        [Key]
        [StringLength(50)]
        public string CategoryId {get; set;}

        [Required]
        [StringLength(50)]
        public string CategoryName { get; set; }

        public ICollection<ProductEntity> Products { get; set; }
    }
}